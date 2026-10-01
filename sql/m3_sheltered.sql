-- Copied from wcspm.yml (hmisguru/westchester-dac, main): "Metric 3.2 — Unduplicated Sheltered Persons".
-- Regenerate with scripts/extract_sql.py; do not edit by hand.
WITH bounds AS (
  SELECT
    @report_start AS cur_start,
    DATE_SUB(DATE_ADD(@report_start, INTERVAL 1 YEAR), INTERVAL 1 DAY) AS cur_end,
    DATE_SUB(@report_start, INTERVAL 1 YEAR) AS prev_start,
    DATE_SUB(@report_start, INTERVAL 1 DAY) AS prev_end
),
qualifying_projects AS (
  SELECT p.ProjectID, p.ProjectType
  FROM wchmiscsv.Project p
  WHERE p.ContinuumProject = 1
    AND p.ProjectType IN (0, 1, 2, 8)
    AND (@all_projects OR p.ProjectID IN UNNEST(@project_ids))
),
periods AS (
  SELECT 'Previous FY' AS period, prev_start AS period_start, prev_end AS period_end FROM bounds
  UNION ALL
  SELECT 'Current FY', cur_start, cur_end FROM bounds
),
ee_based AS (
  -- "ex.ExitDate > en.EntryDate" (in addition to the period-overlap test below) rejects
  -- zero-length enrollments (EntryDate = ExitDate): without it, a same-day entry/exit can
  -- satisfy both overlap inequalities despite representing zero actual nights, which would
  -- violate "Method 5: 1+ Nights Active" -- confirmed live against ES-EE enrollments that
  -- would otherwise be miscounted as active.
  SELECT en.PersonalID, qp.ProjectType, pe.period
  FROM wchmiscsv.Enrollment en
  JOIN qualifying_projects qp ON en.ProjectID = qp.ProjectID
  LEFT JOIN wchmiscsv.Exit ex ON en.EnrollmentID = ex.EnrollmentID
  CROSS JOIN periods pe
  WHERE qp.ProjectType IN (0, 2, 8)
    AND (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
    AND en.EntryDate <= pe.period_end
    AND (ex.ExitDate IS NULL OR (ex.ExitDate > pe.period_start AND ex.ExitDate > en.EntryDate))
),
nbn AS (
  SELECT s.PersonalID, 1 AS ProjectType, pe.period
  FROM wchmiscsv.Services s
  JOIN wchmiscsv.Enrollment en ON s.EnrollmentID = en.EnrollmentID
  JOIN qualifying_projects qp ON en.ProjectID = qp.ProjectID
  LEFT JOIN wchmiscsv.Exit ex ON en.EnrollmentID = ex.EnrollmentID
  CROSS JOIN periods pe
  WHERE qp.ProjectType = 1
    AND s.RecordType = 200
    AND (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
    AND s.DateProvided >= pe.period_start AND s.DateProvided <= pe.period_end
    AND s.DateProvided >= en.EntryDate
    AND (ex.ExitDate IS NULL OR s.DateProvided < ex.ExitDate)
),
active AS (
  SELECT * FROM ee_based
  UNION ALL
  SELECT * FROM nbn
),
bucketed AS (
  SELECT
    period,
    CASE WHEN ProjectType IN (0, 1) THEN 'Emergency Shelter'
         WHEN ProjectType = 8 THEN 'Safe Haven'
         WHEN ProjectType = 2 THEN 'Transitional Housing' END AS bucket,
    PersonalID
  FROM active
),
by_bucket AS (
  SELECT period, bucket, COUNT(DISTINCT PersonalID) AS cnt
  FROM bucketed
  GROUP BY period, bucket
),
total AS (
  SELECT period, 'Total (Unduplicated)' AS bucket, COUNT(DISTINCT PersonalID) AS cnt
  FROM bucketed
  GROUP BY period
),
combined AS (
  SELECT * FROM total
  UNION ALL
  SELECT * FROM by_bucket
)
SELECT
  bucket,
  MAX(CASE WHEN period = 'Current FY' THEN cnt END) AS current_fy,
  MAX(CASE WHEN period = 'Previous FY' THEN cnt END) AS previous_fy,
  MAX(CASE WHEN period = 'Current FY' THEN cnt END) - MAX(CASE WHEN period = 'Previous FY' THEN cnt END) AS difference
FROM combined
GROUP BY bucket
ORDER BY CASE bucket
  WHEN 'Total (Unduplicated)' THEN 1
  WHEN 'Emergency Shelter' THEN 2
  WHEN 'Safe Haven' THEN 3
  WHEN 'Transitional Housing' THEN 4
END
