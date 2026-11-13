-- Hand-written, NOT generated from a wcdash YAML -- see sql/homeless_reach.sql's
-- own header comment for the shared report universe, Active Clients
-- convention, and the Street Outreach same-day-contact exemption this file
-- reuses verbatim. Feeds the Homeless dashboard's Overview tab trend charts
-- ("Persons/Households active by project type over time").
--
-- 12 trailing COMPLETE calendar months, ending at the most recently
-- complete month as of the HMIS export's own MAX(ExportEndDate) -- per
-- explicit request, to match sql/homeless_flow.sql's own window exactly
-- (same `latest_complete_month` derivation and 12-month `months` CTE),
-- in place of this file's own earlier 8-trailing-calendar-quarters grain
-- (which matched `/bridge/`'s own calendar-quarter convention instead;
-- that match no longer applies now that this file matches homeless_flow.sql
-- instead).
--
-- Every (month, project_type) combination the current Project Type filter
-- allows is in the output even when genuinely zero people are active that
-- month -- `period_types` cross-joins the canonical `periods` list against
-- every qualifying project type and `LEFT JOIN`s the actual counts onto it,
-- the same "join from a canonical list, don't rely on COUNT/GROUP BY to
-- emit a row for an empty group" pattern sql/homeless_flow.sql's own header
-- documents. This replaces the JS-side zero-fill `renderTrendChart()`
-- previously needed to patch this identical gap after the fact (see this
-- file's own prior header comment, preserved in git history) -- now
-- redundant and removed from homelessness.js.
--
-- Unlike sql/homeless_reach.sql, Project Type here is the chart's own color
-- dimension (one output row per month x project type), not folded into a
-- single filtered total -- but the Project Type filter still applies the
-- same way it does in homeless_reach.sql, narrowing qualifying_projects
-- down to one component when a specific type is selected (so selecting
-- "Street Outreach" shows only that one line).
WITH export_info AS (
  SELECT MAX(ExportEndDate) AS export_end FROM wchmiscsv.Export
),
latest_complete_month AS (
  SELECT IF(
    export_end = LAST_DAY(export_end, MONTH),
    DATE_TRUNC(export_end, MONTH),
    DATE_SUB(DATE_TRUNC(export_end, MONTH), INTERVAL 1 MONTH)
  ) AS m_start
  FROM export_info
),
months AS (
  SELECT DATE_SUB(m_start, INTERVAL n MONTH) AS month_start
  FROM latest_complete_month, UNNEST(GENERATE_ARRAY(0, 11)) AS n
),
periods AS (
  SELECT
    FORMAT_DATE('%b %Y', month_start) AS period,
    month_start AS period_start,
    DATE_SUB(DATE_ADD(month_start, INTERVAL 1 MONTH), INTERVAL 1 DAY) AS period_end
  FROM months
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
  SELECT period, project_type, PersonalID, HouseholdID
  FROM classified
  WHERE ('{{ filters.household_type }}' = 'All Household Types' OR household_type = '{{ filters.household_type }}')
),
counts AS (
  SELECT period, project_type,
    COUNT(DISTINCT PersonalID) AS persons,
    COUNT(DISTINCT HouseholdID) AS households
  FROM filtered
  GROUP BY period, project_type
),
period_types AS (
  SELECT pe.period, pe.period_start, qp.project_type
  FROM periods pe
  CROSS JOIN (SELECT DISTINCT project_type FROM qualifying_projects) qp
)
SELECT pt.period, pt.project_type,
  COALESCE(c.persons, 0) AS persons,
  COALESCE(c.households, 0) AS households
FROM period_types pt
LEFT JOIN counts c ON c.period = pt.period AND c.project_type = pt.project_type
ORDER BY pt.period_start, pt.project_type
