-- Hand-written, NOT generated from wcspm.yml -- "Local Measure 5.3" has no HUD SPM
-- equivalent and isn't a widget on the live DAC dashboard (which only defines Measures
-- 5.1 and 5.2 -- see sql/m5_first_time.sql and sql/m5_2_first_time_ph.sql), so there's
-- no source-of-truth widget to extract this from. See CLAUDE.md's "First-time
-- homelessness including Street Outreach (Local Measure 5.3, non-HUD metric)" section
-- for the full design rationale. Regenerate nothing -- edit this file directly if the
-- definition ever needs to change.
--
-- A near-verbatim copy of sql/m5_first_time.sql's own Measure 5.1 logic (ES/SH/TH,
-- ProjectType 0, 1, 2, 8), with Street Outreach (ProjectType 4) added to BOTH
-- entry_projects (the population being checked) and scan_projects (what counts as
-- "prior activity" when deciding if someone is first-time), per explicit request --
-- a person entering via Street Outreach counts toward the population, and prior
-- Street Outreach contact disqualifies someone else as "first time," symmetrically.
WITH bounds AS (
  SELECT
    @report_start AS cur_start,
    DATE_SUB(DATE_ADD(@report_start, INTERVAL 1 YEAR), INTERVAL 1 DAY) AS cur_end,
    DATE_SUB(@report_start, INTERVAL 1 YEAR) AS prev_start,
    DATE_SUB(@report_start, INTERVAL 1 DAY) AS prev_end
),
periods AS (
  SELECT 'Previous FY' AS period, prev_start AS report_start, prev_end AS report_end FROM bounds
  UNION ALL
  SELECT 'Current FY', cur_start, cur_end FROM bounds
),
entry_projects AS (
  SELECT p.ProjectID
  FROM wchmiscsv.Project p
  WHERE p.ContinuumProject = 1
    AND p.ProjectType IN (0, 1, 2, 4, 8)
),
scan_projects AS (
  SELECT p.ProjectID
  FROM wchmiscsv.Project p
  WHERE p.ContinuumProject = 1
    AND p.ProjectType IN (0, 1, 2, 3, 4, 8, 9, 10, 13)
),
entries AS (
  SELECT en.PersonalID, en.EntryDate, pe.period, pe.report_start
  FROM wchmiscsv.Enrollment en
  JOIN entry_projects ep ON en.ProjectID = ep.ProjectID
  CROSS JOIN periods pe
  WHERE en.EntryDate >= pe.report_start AND en.EntryDate <= pe.report_end
    AND (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
),
client_start AS (
  SELECT PersonalID, period, report_start, MIN(EntryDate) AS client_start_date
  FROM entries
  GROUP BY PersonalID, period, report_start
),
prior_history AS (
  SELECT DISTINCT cs.PersonalID, cs.period
  FROM client_start cs
  JOIN wchmiscsv.Enrollment en2 ON en2.PersonalID = cs.PersonalID AND en2.EntryDate < cs.client_start_date
  JOIN scan_projects sp ON en2.ProjectID = sp.ProjectID
  LEFT JOIN wchmiscsv.Exit ex2 ON en2.EnrollmentID = ex2.EnrollmentID
  WHERE (en2.EnrollmentCoC = 'NY-604' OR en2.EnrollmentCoC IS NULL)
    AND (
      ex2.ExitDate IS NULL
      OR ex2.ExitDate >= GREATEST(
        DATE_SUB(cs.report_start, INTERVAL 7 YEAR),
        DATE_SUB(cs.client_start_date, INTERVAL 730 DAY)
      )
    )
),
metrics AS (
  SELECT cs.period, 'Persons with entries' AS row_label, COUNT(DISTINCT cs.PersonalID) AS cnt
  FROM client_start cs
  GROUP BY cs.period
  UNION ALL
  SELECT cs.period, 'Had activity in the prior 24 months' AS row_label, COUNT(DISTINCT ph.PersonalID) AS cnt
  FROM client_start cs
  JOIN prior_history ph ON ph.PersonalID = cs.PersonalID AND ph.period = cs.period
  GROUP BY cs.period
  UNION ALL
  SELECT cs.period, 'Newly homeless (no prior activity)' AS row_label,
    COUNT(DISTINCT cs.PersonalID) - COUNT(DISTINCT ph.PersonalID) AS cnt
  FROM client_start cs
  LEFT JOIN prior_history ph ON ph.PersonalID = cs.PersonalID AND ph.period = cs.period
  GROUP BY cs.period
)
SELECT
  row_label,
  MAX(CASE WHEN period = 'Current FY' THEN cnt END) AS current_fy,
  MAX(CASE WHEN period = 'Previous FY' THEN cnt END) AS previous_fy,
  MAX(CASE WHEN period = 'Current FY' THEN cnt END) - MAX(CASE WHEN period = 'Previous FY' THEN cnt END) AS difference
FROM metrics
GROUP BY row_label
ORDER BY CASE row_label
  WHEN 'Persons with entries' THEN 1
  WHEN 'Had activity in the prior 24 months' THEN 2
  WHEN 'Newly homeless (no prior activity)' THEN 3
END
