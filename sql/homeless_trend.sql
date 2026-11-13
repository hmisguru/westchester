-- Hand-written, NOT generated from a wcdash YAML -- see sql/homeless_reach.sql's
-- own header comment for the shared report universe, Active Clients
-- convention, and the Street Outreach same-day-contact exemption this file
-- reuses verbatim (just generalized from 2 fixed FY-long periods to 8
-- trailing calendar quarters). Feeds the Homeless dashboard's Overview tab
-- trend charts ("Persons/Households active by project type over time").
--
-- 8 trailing CALENDAR quarters (not fiscal-year quarters), ending at the
-- most recently COMPLETE quarter as of the HMIS export's own
-- MAX(ExportEndDate) -- the same "most recent complete period" posture
-- spm.json.py's own fiscal_year() uses, just quarter-grained. Matches
-- bridge/dashboard.yml's own FORMAT_DATE('%Y Q%Q', ...) calendar-quarter
-- convention for its "over time" trend charts, not this repo's own
-- FY-October-start convention.
--
-- Unlike sql/homeless_reach.sql, Project Type here is the chart's own color
-- dimension (one output row per quarter x project type), not folded into a
-- single filtered total -- but the Project Type filter still applies the
-- same way it does in homeless_reach.sql, narrowing qualifying_projects
-- down to one component when a specific type is selected (so selecting
-- "Street Outreach" shows only that one line, exactly like Bridge's own
-- project-type filter narrows its trend chart to one series).
WITH export_info AS (
  SELECT MAX(ExportEndDate) AS export_end FROM wchmiscsv.Export
),
latest_complete_quarter AS (
  SELECT IF(
    export_end = LAST_DAY(export_end, QUARTER),
    DATE_TRUNC(export_end, QUARTER),
    DATE_SUB(DATE_TRUNC(export_end, QUARTER), INTERVAL 3 MONTH)
  ) AS q_start
  FROM export_info
),
quarters AS (
  SELECT DATE_SUB(q_start, INTERVAL n * 3 MONTH) AS period_start
  FROM latest_complete_quarter, UNNEST(GENERATE_ARRAY(0, 7)) AS n
),
periods AS (
  SELECT
    FORMAT_DATE('%Y Q%Q', period_start) AS period,
    period_start,
    DATE_SUB(DATE_ADD(period_start, INTERVAL 3 MONTH), INTERVAL 1 DAY) AS period_end
  FROM quarters
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
)
SELECT period, project_type,
  COUNT(DISTINCT PersonalID) AS persons,
  COUNT(DISTINCT HouseholdID) AS households
FROM classified
WHERE ('{{ filters.household_type }}' = 'All Household Types' OR household_type = '{{ filters.household_type }}')
GROUP BY period, project_type
ORDER BY period, project_type
