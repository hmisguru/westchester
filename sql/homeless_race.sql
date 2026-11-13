-- Hand-written, NOT generated from a wcdash YAML -- see sql/homeless_reach.sql's
-- own header comment for the shared report universe, Active Clients
-- convention, Street Outreach same-day-contact exemption, and household-
-- determination machinery this file reuses verbatim (through the
-- `classified` CTE) for Project Type/Household Type filtering. Feeds the
-- Homeless dashboard's Demographics tab Race pie (Current FY only) and QoQ
-- table (Current vs. Previous FY) -- both from this one query, in long
-- format (one row per period x race), unlike bridge/dashboard.yml's own
-- Race widgets, which are two separate queries (a current-only pie, a
-- current-vs-previous table) against the same Sheet data. The page builds
-- both widgets from this single result: the pie filters to period =
-- 'Current FY', the table pivots both periods into current/previous/change
-- columns client-side.
--
-- Race is read directly off wchmiscsv.Client's own 2024 HUD Data Standards
-- race fields (AmIndAKNative/Asian/BlackAfAmerican/MidEastNAfrican/
-- NativeHIPacific/White -- each a separate multi-select checkbox, value 1
-- meaning selected), NOT HispanicLatinao -- per explicit instruction, this
-- dashboard keeps Race and Ethnicity as two separate charts (see
-- sql/homeless_ethnicity.sql), even though HUD's current schema folds
-- Hispanic/Latino(a) in as a 7th race checkbox rather than a separate
-- ethnicity column. A person with more than one of the 6 non-Hispanic race
-- boxes checked buckets as "Multiple Races", matching
-- bridge/dashboard.yml's own "Multiple Race selections" bucket. A person
-- with none of the 6 checked (regardless of HispanicLatinao) is excluded
-- entirely, matching that same widget's own "Race: Not provided/missing"
-- exclusion -- this can undercount Hispanic-only clients who didn't also
-- check a race box, which is a real HMIS reporting quirk this dataset
-- inherits from the 2024 Data Standards' own combined race/ethnicity model,
-- not a bug in this query.
--
-- Person-level, one row per (period, race): a person is counted once per
-- race category they selected, so the sum across categories for a period
-- can exceed that period's own Persons Active total (the same multi-select
-- convention bridge/dashboard.yml's own Race pie already has).
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
  SELECT c.PersonalID, c.period
  FROM classified c
  WHERE ('{{ filters.household_type }}' = 'All Household Types' OR c.household_type = '{{ filters.household_type }}')
),
races AS (
  SELECT
    f.period,
    f.PersonalID,
    cl.AmIndAKNative = 1 AS is_aian,
    cl.Asian = 1 AS is_asian,
    cl.BlackAfAmerican = 1 AS is_black,
    cl.MidEastNAfrican = 1 AS is_mena,
    cl.NativeHIPacific = 1 AS is_nhpi,
    cl.White = 1 AS is_white
  FROM filtered f
  JOIN wchmiscsv.Client cl ON cl.PersonalID = f.PersonalID
),
bucketed AS (
  SELECT
    period,
    PersonalID,
    (CAST(is_aian AS INT64) + CAST(is_asian AS INT64) + CAST(is_black AS INT64) + CAST(is_mena AS INT64) + CAST(is_nhpi AS INT64) + CAST(is_white AS INT64)) AS race_count,
    is_aian, is_asian, is_black, is_mena, is_nhpi, is_white
  FROM races
)
SELECT period, race, COUNT(DISTINCT PersonalID) AS persons
FROM (
  SELECT period, PersonalID,
    CASE
      WHEN race_count = 0 THEN NULL
      WHEN race_count > 1 THEN 'Multiple Races'
      WHEN is_aian THEN 'AI/AN or Indigenous'
      WHEN is_asian THEN 'Asian'
      WHEN is_black THEN 'Black/African-American'
      WHEN is_mena THEN 'MENA'
      WHEN is_nhpi THEN 'NH/Pacific Islander'
      WHEN is_white THEN 'White'
    END AS race
  FROM bucketed
)
WHERE race IS NOT NULL
GROUP BY period, race
ORDER BY period, race
