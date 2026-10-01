-- Hand-written, NOT generated from wcspm.yml -- unlike every other file in this
-- directory, "People in Street Outreach" has no HUD SPM equivalent and isn't a
-- widget on the live DAC dashboard, so there's no source-of-truth widget to
-- extract this from. See CLAUDE.md's "People in Street Outreach (non-HUD
-- metric)" section for the full design rationale. Regenerate nothing -- edit
-- this file directly if the definition ever needs to change.
WITH bounds AS (
  SELECT
    @report_start AS cur_start,
    DATE_SUB(DATE_ADD(@report_start, INTERVAL 1 YEAR), INTERVAL 1 DAY) AS cur_end,
    DATE_SUB(@report_start, INTERVAL 1 YEAR) AS prev_start,
    DATE_SUB(@report_start, INTERVAL 1 DAY) AS prev_end
),
qualifying_projects AS (
  SELECT p.ProjectID
  FROM wchmiscsv.Project p
  WHERE p.ContinuumProject = 1 AND p.ProjectType = 4
),
periods AS (
  SELECT 'Previous FY' AS period, prev_start AS period_start, prev_end AS period_end FROM bounds
  UNION ALL
  SELECT 'Current FY', cur_start, cur_end FROM bounds
),
so_active AS (
  -- No zero-length-enrollment exclusion here, unlike Metric 3.2's ee_based
  -- (sql/m3_sheltered.sql): Street Outreach isn't residential, so a client can
  -- legitimately be contacted as street homeless on a single day with no
  -- multi-day span to speak of -- the same exception already applied to
  -- Measure 2's return-match logic (sql/m2_returns.sql).
  SELECT DISTINCT en.PersonalID, pe.period
  FROM wchmiscsv.Enrollment en
  JOIN qualifying_projects qp ON en.ProjectID = qp.ProjectID
  LEFT JOIN wchmiscsv.Exit ex ON en.EnrollmentID = ex.EnrollmentID
  CROSS JOIN periods pe
  WHERE (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
    AND en.EntryDate <= pe.period_end
    AND (ex.ExitDate IS NULL OR ex.ExitDate > pe.period_start)
),
by_period AS (
  SELECT period, COUNT(DISTINCT PersonalID) AS cnt
  FROM so_active
  GROUP BY period
)
SELECT
  MAX(CASE WHEN period = 'Current FY' THEN cnt END) AS current_fy,
  MAX(CASE WHEN period = 'Previous FY' THEN cnt END) AS previous_fy
FROM by_period
