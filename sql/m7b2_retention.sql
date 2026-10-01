-- Copied from wcspm.yml (hmisguru/westchester, main): "Metric 7b.2 — Successful Placement/Retention in Permanent Housing".
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
psh_projects AS (
  SELECT p.ProjectID
  FROM wchmiscsv.Project p
  WHERE p.ContinuumProject = 1
    AND p.ProjectType IN (3, 9, 10)
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
  JOIN psh_projects pp ON en.ProjectID = pp.ProjectID
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
enrollments AS (
  SELECT en.PersonalID, en.EnrollmentID, en.EntryDate, em.MoveInDate, ex.ExitDate, ex.Destination,
    pe.period, pe.report_start, pe.report_end
  FROM wchmiscsv.Enrollment en
  JOIN psh_projects pp ON en.ProjectID = pp.ProjectID
  LEFT JOIN wchmiscsv.Exit ex ON en.EnrollmentID = ex.EnrollmentID
  CROSS JOIN periods pe
  LEFT JOIN effective_movein em ON em.EnrollmentID = en.EnrollmentID AND em.period = pe.period
  WHERE (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
),
stayer_flag AS (
  SELECT PersonalID, period,
    MAX(CASE WHEN EntryDate <= report_end AND (ExitDate IS NULL OR ExitDate > report_end) THEN 1 ELSE 0 END) AS is_stayer
  FROM enrollments
  GROUP BY PersonalID, period
),
latest_stay_for_stayers AS (
  SELECT e.PersonalID, e.period, e.MoveInDate, e.report_end,
    ROW_NUMBER() OVER (PARTITION BY e.PersonalID, e.period ORDER BY e.EntryDate DESC, e.EnrollmentID ASC) AS rn
  FROM enrollments e
  JOIN stayer_flag sf ON sf.PersonalID = e.PersonalID AND sf.period = e.period AND sf.is_stayer = 1
),
stayers_included AS (
  SELECT PersonalID, period
  FROM latest_stay_for_stayers
  WHERE rn = 1 AND MoveInDate IS NOT NULL AND MoveInDate <= report_end
),
leaver_exits AS (
  SELECT e.PersonalID, e.period, e.ExitDate, e.Destination, e.MoveInDate, e.report_end,
    ROW_NUMBER() OVER (PARTITION BY e.PersonalID, e.period ORDER BY e.ExitDate DESC, e.EnrollmentID ASC) AS rn
  FROM enrollments e
  JOIN stayer_flag sf ON sf.PersonalID = e.PersonalID AND sf.period = e.period AND sf.is_stayer = 0
  WHERE e.ExitDate IS NOT NULL AND e.ExitDate >= e.report_start AND e.ExitDate <= e.report_end
),
leavers_included AS (
  SELECT PersonalID, period, Destination
  FROM leaver_exits
  WHERE rn = 1 AND MoveInDate IS NOT NULL AND MoveInDate <= report_end
),
leavers_classified AS (
  SELECT
    PersonalID, period,
    CASE
      WHEN Destination BETWEEN 400 AND 499 THEN 'permanent'
      WHEN Destination IN (206, 215, 225, 24) THEN 'exclude'
      ELSE 'neutral'
    END AS bucket
  FROM leavers_included
),
leavers_remaining AS (
  SELECT * FROM leavers_classified WHERE bucket != 'exclude'
),
period_summary AS (
  SELECT
    pe.period,
    COUNT(DISTINCT si.PersonalID) AS stayer_cnt,
    COUNT(DISTINCT lr.PersonalID) AS leaver_cnt,
    COUNT(DISTINCT CASE WHEN lr.bucket = 'permanent' THEN lr.PersonalID END) AS leaver_permanent_cnt
  FROM periods pe
  LEFT JOIN stayers_included si ON si.period = pe.period
  LEFT JOIN leavers_remaining lr ON lr.period = pe.period
  GROUP BY pe.period
),
final_rows AS (
  SELECT period, 'Universe: PH-PSH/HO/HS stayers and leavers with move-in' AS row_label, 1 AS row_order,
    CAST(stayer_cnt + leaver_cnt AS FLOAT64) AS val FROM period_summary
  UNION ALL
  SELECT period, 'Remained housed or exited to permanent housing destination', 2,
    CAST(stayer_cnt + leaver_permanent_cnt AS FLOAT64) FROM period_summary
  UNION ALL
  SELECT period, '% Successful exits/retention', 3,
    ROUND(SAFE_DIVIDE(stayer_cnt + leaver_permanent_cnt, stayer_cnt + leaver_cnt) * 100, 2) FROM period_summary
)
SELECT
  row_label,
  MAX(CASE WHEN period = 'Current FY' THEN val END) AS current_fy,
  MAX(CASE WHEN period = 'Previous FY' THEN val END) AS previous_fy,
  MAX(CASE WHEN period = 'Current FY' THEN val END) - MAX(CASE WHEN period = 'Previous FY' THEN val END) AS difference
FROM final_rows
GROUP BY row_label, row_order
ORDER BY row_order
