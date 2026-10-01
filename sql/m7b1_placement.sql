-- Copied from wcspm.yml (hmisguru/westchester-dac, main): "Metric 7b.1 — Successful Placement (ES, SH, TH, PH-RRH, PH exits without move-in)".
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
b1_projects AS (
  SELECT p.ProjectID, p.ProjectType
  FROM wchmiscsv.Project p
  WHERE p.ContinuumProject = 1
    AND p.ProjectType IN (0, 1, 2, 3, 8, 9, 10, 13)
    AND (@all_projects OR p.ProjectID IN UNNEST(@project_ids))
),
own_movein AS (
  -- Housing move-in date is only required on the Head of Household; inherit it to
  -- other household members per the HMIS Reporting Glossary's "Handling Housing
  -- Move-In Dates" rules.
  SELECT en.EnrollmentID, en.HouseholdID, en.RelationshipToHoH, en.EntryDate, ex.ExitDate, pe.period,
    CASE WHEN en.MoveInDate IS NOT NULL
      AND en.MoveInDate >= en.EntryDate
      AND (ex.ExitDate IS NULL OR en.MoveInDate <= ex.ExitDate)
      AND en.MoveInDate <= pe.report_end
    THEN en.MoveInDate END AS own_move_in
  FROM wchmiscsv.Enrollment en
  JOIN b1_projects bp ON en.ProjectID = bp.ProjectID
  LEFT JOIN wchmiscsv.Exit ex ON en.EnrollmentID = ex.EnrollmentID
  CROSS JOIN periods pe
),
hoh_movein AS (
  SELECT HouseholdID, period, own_move_in AS hoh_move_in_date
  FROM own_movein
  WHERE RelationshipToHoH = 1
),
effective_movein AS (
  SELECT ov.EnrollmentID, ov.period,
    CASE
      WHEN ov.RelationshipToHoH = 1 THEN ov.own_move_in
      WHEN hm.hoh_move_in_date IS NULL THEN NULL
      WHEN ov.EntryDate <= hm.hoh_move_in_date
           AND (ov.ExitDate IS NULL OR ov.ExitDate >= hm.hoh_move_in_date) THEN hm.hoh_move_in_date
      WHEN ov.EntryDate > hm.hoh_move_in_date THEN ov.EntryDate
      ELSE NULL
    END AS MoveInDate
  FROM own_movein ov
  LEFT JOIN hoh_movein hm ON hm.HouseholdID = ov.HouseholdID AND hm.period = ov.period
),
exits AS (
  SELECT en.PersonalID, en.EnrollmentID, bp.ProjectType, ex.ExitDate, ex.Destination, em.MoveInDate, pe.period, pe.report_end
  FROM wchmiscsv.Enrollment en
  JOIN b1_projects bp ON en.ProjectID = bp.ProjectID
  JOIN wchmiscsv.Exit ex ON en.EnrollmentID = ex.EnrollmentID
  CROSS JOIN periods pe
  LEFT JOIN effective_movein em ON em.EnrollmentID = en.EnrollmentID AND em.period = pe.period
  WHERE ex.ExitDate >= pe.report_start AND ex.ExitDate <= pe.report_end
    AND (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
),
still_active AS (
  SELECT DISTINCT en.PersonalID, pe.period
  FROM wchmiscsv.Enrollment en
  JOIN b1_projects bp ON en.ProjectID = bp.ProjectID
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
  SELECT PersonalID, period, ProjectType, ExitDate, Destination, MoveInDate, report_end,
    ROW_NUMBER() OVER (PARTITION BY PersonalID, period ORDER BY ExitDate DESC, EnrollmentID ASC) AS rn
  FROM leavers_raw
),
move_in_filtered AS (
  SELECT * FROM latest_exit
  WHERE rn = 1
    AND NOT (ProjectType IN (3, 9, 10) AND MoveInDate IS NOT NULL AND MoveInDate <= report_end)
),
classified AS (
  SELECT
    PersonalID, period,
    CASE
      WHEN Destination BETWEEN 400 AND 499 THEN 'permanent'
      WHEN Destination IN (206, 215, 225, 24) THEN 'exclude'
      ELSE 'neutral'
    END AS bucket
  FROM move_in_filtered
),
remaining AS (
  SELECT * FROM classified WHERE bucket != 'exclude'
),
period_summary AS (
  SELECT
    period,
    COUNT(DISTINCT PersonalID) AS universe,
    COUNT(DISTINCT CASE WHEN bucket = 'permanent' THEN PersonalID END) AS permanent
  FROM remaining
  GROUP BY period
),
final_rows AS (
  SELECT period, 'Universe: ES/SH/TH/PH-RRH leavers + other PH leavers without move-in' AS row_label, 1 AS row_order, CAST(universe AS FLOAT64) AS val FROM period_summary
  UNION ALL
  SELECT period, 'Exited to permanent housing destination', 2, CAST(permanent AS FLOAT64) FROM period_summary
  UNION ALL
  SELECT period, '% Successful exits', 3, ROUND(SAFE_DIVIDE(permanent, universe) * 100, 2) FROM period_summary
)
SELECT
  row_label,
  MAX(CASE WHEN period = 'Current FY' THEN val END) AS current_fy,
  MAX(CASE WHEN period = 'Previous FY' THEN val END) AS previous_fy,
  MAX(CASE WHEN period = 'Current FY' THEN val END) - MAX(CASE WHEN period = 'Previous FY' THEN val END) AS difference
FROM final_rows
GROUP BY row_label, row_order
ORDER BY row_order
