-- Hand-written, NOT generated from a wcdash YAML -- see sql/homeless_reach.sql's
-- own header comment for the shared report universe, Active Clients
-- convention, and household-determination machinery this file reuses
-- verbatim (through the `household_ages`/`classified` CTEs) for Project
-- Type/Household Type filtering. Feeds the Homeless dashboard's
-- Demographics tab Priority Households QoQ table (Current vs. Previous
-- FY), in long format (one row per period x indicator) -- the page pivots
-- both periods into current/previous/change columns client-side, same
-- convention as sql/homeless_race.sql.
--
-- 4 indicators, a household counts if ANY member meets the condition (not
-- just the household's own representative person):
--   Households Age 55+   -- any member's age (as of the household's own
--                            reference enrollment date, same age-math
--                            convention as household_ages elsewhere in this
--                            file) is 55 or older.
--   Disabled Households   -- any member has a wchmiscsv.Disabilities row
--                            with DisabilityResponse = 1, recorded on or
--                            before the reference date (their own most
--                            recent such record as of that date, so a
--                            later update that withdraws the response isn't
--                            still counted as of an earlier reference date).
--   Veteran Households    -- any member's wchmiscsv.Client.VeteranStatus = 1.
--   DV Survivor Households -- any member's most recent
--                            wchmiscsv.HealthAndDV row as of the reference
--                            date has DomesticViolenceSurvivor = 1,
--                            regardless of CurrentlyFleeing -- matches the
--                            sibling hmisguru/baltimore repo's own
--                            dashboard.json.py convention for this same
--                            measure ("a household counts if its set is
--                            anything other than 'No history of domestic
--                            violence reported'").
-- Order matches PRIORITY_HOUSEHOLDS_ORDER in src/components/homeless.js.
WITH bounds AS (
  SELECT
    @report_start AS cur_start,
    DATE_SUB(DATE_ADD(@report_start, INTERVAL 1 YEAR), INTERVAL 1 DAY) AS cur_end,
    DATE_SUB(@report_start, INTERVAL 1 YEAR) AS prev_start,
    DATE_SUB(@report_start, INTERVAL 1 DAY) AS prev_end
),
periods AS (
  SELECT 'Previous FY' AS period, prev_start AS period_start, prev_end AS period_end FROM bounds
  UNION ALL
  SELECT 'Current FY', cur_start, cur_end FROM bounds
),
qualifying_projects AS (
  SELECT
    p.ProjectID,
    CASE
      WHEN p.ProjectType IN (0, 1) THEN 'Emergency Shelter'
      WHEN p.ProjectType = 2 THEN 'Transitional Housing'
      WHEN p.ProjectType = 4 THEN 'Street Outreach'
    END AS project_type
  FROM wchmiscsv.Project p
  WHERE p.ContinuumProject = 1 AND p.ProjectType IN (0, 1, 2, 4)
    AND ('{{ filters.project_type }}' = 'All Project Types' OR CASE
      WHEN p.ProjectType IN (0, 1) THEN 'Emergency Shelter'
      WHEN p.ProjectType = 2 THEN 'Transitional Housing'
      WHEN p.ProjectType = 4 THEN 'Street Outreach'
    END = '{{ filters.project_type }}')
),
active_enrollments AS (
  SELECT en.EnrollmentID, en.PersonalID, en.HouseholdID, en.EntryDate, qp.project_type, pe.period
  FROM wchmiscsv.Enrollment en
  JOIN qualifying_projects qp ON en.ProjectID = qp.ProjectID
  LEFT JOIN wchmiscsv.Exit ex ON en.EnrollmentID = ex.EnrollmentID
  CROSS JOIN periods pe
  WHERE (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
    AND en.EntryDate <= pe.period_end
    AND (
      ex.ExitDate IS NULL
      OR (qp.project_type = 'Street Outreach' AND ex.ExitDate > pe.period_start)
      OR (qp.project_type != 'Street Outreach' AND ex.ExitDate > pe.period_start AND ex.ExitDate > en.EntryDate)
    )
),
rep AS (
  SELECT PersonalID, period, project_type, HouseholdID, EntryDate FROM (
    SELECT PersonalID, period, project_type, HouseholdID, EntryDate,
      ROW_NUMBER() OVER (PARTITION BY PersonalID, period, project_type ORDER BY EntryDate DESC, EnrollmentID DESC) AS rn
    FROM active_enrollments
  )
  WHERE rn = 1
),
household_members AS (
  SELECT
    r.PersonalID AS rep_person, r.period, r.project_type, r.HouseholdID, r.EntryDate AS ref_date,
    cl.PersonalID AS member_person,
    CASE
      WHEN cl.DOB IS NULL THEN NULL
      ELSE DATE_DIFF(r.EntryDate, cl.DOB, YEAR)
        - IF(
            EXTRACT(MONTH FROM cl.DOB) * 100 + EXTRACT(DAY FROM cl.DOB)
              > EXTRACT(MONTH FROM r.EntryDate) * 100 + EXTRACT(DAY FROM r.EntryDate),
            1, 0
          )
    END AS age,
    cl.VeteranStatus = 1 AS is_veteran
  FROM rep r
  JOIN wchmiscsv.Enrollment en2 ON en2.HouseholdID = r.HouseholdID
  JOIN wchmiscsv.Project p2 ON en2.ProjectID = p2.ProjectID
  JOIN wchmiscsv.Client cl ON cl.PersonalID = en2.PersonalID
  LEFT JOIN wchmiscsv.Exit ex2 ON ex2.EnrollmentID = en2.EnrollmentID
  WHERE en2.EntryDate <= r.EntryDate
    AND (
      ex2.ExitDate IS NULL
      OR (p2.ProjectType = 4 AND ex2.ExitDate >= r.EntryDate)
      OR (p2.ProjectType != 4 AND ex2.ExitDate > r.EntryDate)
    )
),
-- Each member's own most recent Disabilities response as of the household's
-- reference date, rather than "ever reported any disability" -- a later
-- correction that withdraws an earlier Yes shouldn't still count.
disability_latest AS (
  SELECT PersonalID, DisabilityResponse, InformationDate FROM (
    SELECT PersonalID, DisabilityResponse, InformationDate,
      ROW_NUMBER() OVER (PARTITION BY PersonalID, DisabilityType ORDER BY InformationDate DESC) AS rn
    FROM wchmiscsv.Disabilities
  )
  WHERE rn = 1
),
dv_latest AS (
  SELECT PersonalID, DomesticViolenceSurvivor, InformationDate FROM (
    SELECT PersonalID, DomesticViolenceSurvivor, InformationDate,
      ROW_NUMBER() OVER (PARTITION BY PersonalID ORDER BY InformationDate DESC) AS rn
    FROM wchmiscsv.HealthAndDV
  )
  WHERE rn = 1
),
household_flags AS (
  SELECT
    hm.rep_person, hm.period, hm.project_type, hm.HouseholdID,
    LOGICAL_OR(hm.age IS NOT NULL AND hm.age >= 55) AS has_senior,
    LOGICAL_OR(hm.is_veteran) AS has_veteran,
    LOGICAL_OR(EXISTS (
      SELECT 1 FROM disability_latest dl
      WHERE dl.PersonalID = hm.member_person AND dl.InformationDate <= hm.ref_date AND dl.DisabilityResponse = 1
    )) AS has_disability,
    LOGICAL_OR(EXISTS (
      SELECT 1 FROM dv_latest dv
      WHERE dv.PersonalID = hm.member_person AND dv.InformationDate <= hm.ref_date AND dv.DomesticViolenceSurvivor = 1
    )) AS has_dv
  FROM household_members hm
  GROUP BY hm.rep_person, hm.period, hm.project_type, hm.HouseholdID
),
household_ages AS (
  SELECT rep_person, period, project_type, HouseholdID,
    COUNTIF(age IS NOT NULL AND age >= 18) AS adult_cnt,
    COUNTIF(age IS NOT NULL AND age < 18) AS child_cnt
  FROM household_members
  GROUP BY rep_person, period, project_type, HouseholdID
),
classified AS (
  SELECT
    r.PersonalID, r.period, r.project_type, r.HouseholdID,
    CASE
      WHEN ha.adult_cnt > 0 AND ha.child_cnt = 0 THEN 'Adults Only'
      WHEN ha.adult_cnt > 0 AND ha.child_cnt > 0 THEN 'Families with Children'
      WHEN ha.adult_cnt = 0 AND ha.child_cnt > 0 THEN 'Unaccompanied Minors'
      ELSE 'Unknown Household Type'
    END AS household_type
  FROM rep r
  LEFT JOIN household_ages ha ON ha.rep_person = r.PersonalID AND ha.period = r.period AND ha.project_type = r.project_type
),
filtered AS (
  SELECT DISTINCT c.PersonalID, c.period, c.project_type, c.HouseholdID
  FROM classified c
  WHERE ('{{ filters.household_type }}' = 'All Household Types' OR c.household_type = '{{ filters.household_type }}')
),
scoped_flags AS (
  SELECT f.period, f.HouseholdID, hf.has_senior, hf.has_veteran, hf.has_disability, hf.has_dv
  FROM filtered f
  JOIN household_flags hf ON hf.rep_person = f.PersonalID AND hf.period = f.period AND hf.project_type = f.project_type AND hf.HouseholdID = f.HouseholdID
)
SELECT period, 'Households age 55+' AS indicator, COUNT(DISTINCT HouseholdID) AS households FROM scoped_flags WHERE has_senior GROUP BY period
UNION ALL
SELECT period, 'Disabled households', COUNT(DISTINCT HouseholdID) FROM scoped_flags WHERE has_disability GROUP BY period
UNION ALL
SELECT period, 'Veteran households', COUNT(DISTINCT HouseholdID) FROM scoped_flags WHERE has_veteran GROUP BY period
UNION ALL
SELECT period, 'DV Survivor Households', COUNT(DISTINCT HouseholdID) FROM scoped_flags WHERE has_dv GROUP BY period
ORDER BY period, indicator
