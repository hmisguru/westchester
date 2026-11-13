-- Hand-written, NOT generated from a wcdash YAML -- see sql/homeless_reach.sql's
-- own header comment for the shared report universe, Active Clients
-- convention, and household-determination machinery this file reuses
-- verbatim (through the `classified` CTE) for Project Type/Household Type
-- filtering. Feeds the Homeless dashboard's Demographics tab Age pie
-- (Current FY only) and QoQ table (Current vs. Previous FY) -- both from
-- this one query, in long format, same convention as sql/homeless_race.sql.
--
-- Buckets match bridge/dashboard.yml's own Age widget exactly (<1, 1 to 2,
-- 3 to 5, 6 to 17, 17 year-olds who turned 18, 18 to 21, 22 to 24, 25 to
-- 34, 35 to 44, 45 to 54, 55 to 64, 65 and Older), computed from
-- wchmiscsv.Client.DOB rather than read off a Sheet. Age is computed twice
-- per person -- once as of the fiscal year's own start (Oct 1), once as of
-- its end (Sep 30) -- because "17 year-olds who turned 18" is a transition
-- bucket (HUD's own APR/CAPER age reporting has the same shape): a person
-- who was 17 at the start of the period and turned 18 by its end lands
-- there instead of in "6 to 17" or "18 to 21". Every other bucket uses age
-- as of the period's end. This is a reasonable reconstruction of that HUD
-- convention, not a literal copy of a published spec -- there's no DAC
-- widget's own SQL to copy the exact logic from here, unlike every
-- straight reuse elsewhere in sql/homeless_*.sql.
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
  SELECT en.EnrollmentID, en.PersonalID, en.HouseholdID, en.EntryDate, qp.project_type, pe.period, pe.period_start, pe.period_end
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
  SELECT PersonalID, period, project_type, HouseholdID, EntryDate, period_start, period_end FROM (
    SELECT PersonalID, period, project_type, HouseholdID, EntryDate, period_start, period_end,
      ROW_NUMBER() OVER (PARTITION BY PersonalID, period, project_type ORDER BY EntryDate DESC, EnrollmentID DESC) AS rn
    FROM active_enrollments
  )
  WHERE rn = 1
),
household_members AS (
  SELECT
    r.PersonalID AS rep_person, r.period, r.project_type, r.HouseholdID,
    cl.PersonalID AS member_person,
    CASE
      WHEN cl.DOB IS NULL THEN NULL
      ELSE DATE_DIFF(r.EntryDate, cl.DOB, YEAR)
        - IF(
            EXTRACT(MONTH FROM cl.DOB) * 100 + EXTRACT(DAY FROM cl.DOB)
              > EXTRACT(MONTH FROM r.EntryDate) * 100 + EXTRACT(DAY FROM r.EntryDate),
            1, 0
          )
    END AS age
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
household_ages AS (
  SELECT rep_person, period, project_type, HouseholdID,
    COUNTIF(age IS NOT NULL AND age >= 18) AS adult_cnt,
    COUNTIF(age IS NOT NULL AND age < 18) AS child_cnt
  FROM household_members
  GROUP BY rep_person, period, project_type, HouseholdID
),
classified AS (
  SELECT
    r.PersonalID, r.period, r.project_type, r.HouseholdID, r.period_start, r.period_end,
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
  SELECT DISTINCT c.PersonalID, c.period, c.period_start, c.period_end
  FROM classified c
  WHERE ('{{ filters.household_type }}' = 'All Household Types' OR c.household_type = '{{ filters.household_type }}')
),
aged AS (
  SELECT
    f.period,
    f.PersonalID,
    CASE WHEN cl.DOB IS NULL THEN NULL ELSE
      DATE_DIFF(f.period_start, cl.DOB, YEAR)
        - IF(EXTRACT(MONTH FROM cl.DOB) * 100 + EXTRACT(DAY FROM cl.DOB) > EXTRACT(MONTH FROM f.period_start) * 100 + EXTRACT(DAY FROM f.period_start), 1, 0)
    END AS age_start,
    CASE WHEN cl.DOB IS NULL THEN NULL ELSE
      DATE_DIFF(f.period_end, cl.DOB, YEAR)
        - IF(EXTRACT(MONTH FROM cl.DOB) * 100 + EXTRACT(DAY FROM cl.DOB) > EXTRACT(MONTH FROM f.period_end) * 100 + EXTRACT(DAY FROM f.period_end), 1, 0)
    END AS age_end
  FROM filtered f
  JOIN wchmiscsv.Client cl ON cl.PersonalID = f.PersonalID
)
SELECT period, age_bucket, COUNT(DISTINCT PersonalID) AS persons
FROM (
  SELECT period, PersonalID,
    CASE
      WHEN age_end IS NULL THEN NULL
      WHEN age_start = 17 AND age_end = 18 THEN '17 year-olds who turned 18'
      WHEN age_end < 1 THEN '<1'
      WHEN age_end <= 2 THEN '1 to 2'
      WHEN age_end <= 5 THEN '3 to 5'
      WHEN age_end <= 17 THEN '6 to 17'
      WHEN age_end <= 21 THEN '18 to 21'
      WHEN age_end <= 24 THEN '22 to 24'
      WHEN age_end <= 34 THEN '25 to 34'
      WHEN age_end <= 44 THEN '35 to 44'
      WHEN age_end <= 54 THEN '45 to 54'
      WHEN age_end <= 64 THEN '55 to 64'
      ELSE '65 and Older'
    END AS age_bucket
  FROM aged
)
WHERE age_bucket IS NOT NULL
GROUP BY period, age_bucket
ORDER BY period,
  CASE age_bucket
    WHEN '<1' THEN 1 WHEN '1 to 2' THEN 2 WHEN '3 to 5' THEN 3 WHEN '6 to 17' THEN 4
    WHEN '17 year-olds who turned 18' THEN 5 WHEN '18 to 21' THEN 6 WHEN '22 to 24' THEN 7
    WHEN '25 to 34' THEN 8 WHEN '35 to 44' THEN 9 WHEN '45 to 54' THEN 10
    WHEN '55 to 64' THEN 11 ELSE 12
  END
