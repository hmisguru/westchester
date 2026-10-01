-- Copied from wcspm.yml (hmisguru/westchester-dac, main): "Metric 7a.1 — Successful Placement from Street Outreach".
-- Regenerate with scripts/extract_sql.py; do not edit by hand.
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
so_projects AS (
  SELECT p.ProjectID
  FROM wchmiscsv.Project p
  WHERE p.ContinuumProject = 1
    AND p.ProjectType = 4
    AND (@all_projects OR p.ProjectID IN UNNEST(@project_ids))
),
exits AS (
  SELECT en.PersonalID, en.EnrollmentID, ex.ExitDate, ex.Destination, pe.period
  FROM wchmiscsv.Enrollment en
  JOIN so_projects sp ON en.ProjectID = sp.ProjectID
  JOIN wchmiscsv.Exit ex ON en.EnrollmentID = ex.EnrollmentID
  CROSS JOIN periods pe
  WHERE ex.ExitDate >= pe.report_start AND ex.ExitDate <= pe.report_end
    AND (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
),
still_active AS (
  SELECT DISTINCT en.PersonalID, pe.period
  FROM wchmiscsv.Enrollment en
  JOIN so_projects sp ON en.ProjectID = sp.ProjectID
  LEFT JOIN wchmiscsv.Exit ex ON en.EnrollmentID = ex.EnrollmentID
  CROSS JOIN periods pe
  WHERE en.EntryDate <= pe.report_end
    AND (ex.ExitDate IS NULL OR ex.ExitDate > pe.report_end)
    AND (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
),
leavers_raw AS (
  SELECT e.*
  FROM exits e
  LEFT JOIN still_active sa ON sa.PersonalID = e.PersonalID AND sa.period = e.period
  WHERE sa.PersonalID IS NULL
),
latest_exit AS (
  SELECT PersonalID, period, ExitDate, Destination,
    ROW_NUMBER() OVER (PARTITION BY PersonalID, period ORDER BY ExitDate DESC, EnrollmentID ASC) AS rn
  FROM leavers_raw
),
classified AS (
  SELECT
    PersonalID, period,
    CASE
      WHEN Destination BETWEEN 400 AND 499 THEN 'permanent'
      WHEN Destination IN (206, 24, 329) THEN 'exclude'
      WHEN Destination IN (101, 118, 204, 205, 215, 225, 314, 312, 313, 302, 327, 332) THEN 'other_acceptable'
      ELSE 'neutral'
    END AS bucket
  FROM latest_exit
  WHERE rn = 1
),
remaining AS (
  SELECT * FROM classified WHERE bucket != 'exclude'
),
period_summary AS (
  SELECT
    period,
    COUNT(DISTINCT PersonalID) AS universe,
    COUNT(DISTINCT CASE WHEN bucket = 'other_acceptable' THEN PersonalID END) AS homeless_temp,
    COUNT(DISTINCT CASE WHEN bucket = 'permanent' THEN PersonalID END) AS permanent
  FROM remaining
  GROUP BY period
),
final_rows AS (
  SELECT period, 'Universe: persons who exit Street Outreach' AS row_label, 1 AS row_order, CAST(universe AS FLOAT64) AS val FROM period_summary
  UNION ALL
  SELECT period, 'Exited to homeless, temporary, or institutional destination', 2, CAST(homeless_temp AS FLOAT64) FROM period_summary
  UNION ALL
  SELECT period, 'Exited to permanent housing destination', 3, CAST(permanent AS FLOAT64) FROM period_summary
  UNION ALL
  SELECT period, '% Successful exits', 4, ROUND(SAFE_DIVIDE(homeless_temp + permanent, universe) * 100, 2) FROM period_summary
)
SELECT
  row_label,
  MAX(CASE WHEN period = 'Current FY' THEN val END) AS current_fy,
  MAX(CASE WHEN period = 'Previous FY' THEN val END) AS previous_fy,
  MAX(CASE WHEN period = 'Current FY' THEN val END) - MAX(CASE WHEN period = 'Previous FY' THEN val END) AS difference
FROM final_rows
GROUP BY row_label, row_order
ORDER BY row_order
