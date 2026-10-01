-- Generated from sql/m7a1_street_outreach.sql (Measure 7a.1) and sql/m7b1_placement.sql (Measure 7b.1):
-- people exiting either to a permanent destination, each counted once.
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
b_bounds AS (
  SELECT
    @report_start AS cur_start,
    DATE_SUB(DATE_ADD(@report_start, INTERVAL 1 YEAR), INTERVAL 1 DAY) AS cur_end,
    DATE_SUB(@report_start, INTERVAL 1 YEAR) AS prev_start,
    DATE_SUB(@report_start, INTERVAL 1 DAY) AS prev_end
),
b_periods AS (
  SELECT 'Previous FY' AS period, prev_start AS report_start, prev_end AS report_end FROM b_bounds
  UNION ALL
  SELECT 'Current FY', cur_start, cur_end FROM b_bounds
),
b_b1_projects AS (
  SELECT p.ProjectID, p.ProjectType
  FROM wchmiscsv.Project p
  WHERE p.ContinuumProject = 1
    AND p.ProjectType IN (0, 1, 2, 3, 8, 9, 10, 13)
    AND (@all_projects OR p.ProjectID IN UNNEST(@project_ids))
),
b_own_movein AS (
  SELECT en.EnrollmentID, en.HouseholdID, en.RelationshipToHoH, en.EntryDate, ex.ExitDate, pe.period,
    CASE WHEN en.MoveInDate IS NOT NULL
      AND en.MoveInDate >= en.EntryDate
      AND (ex.ExitDate IS NULL OR en.MoveInDate <= ex.ExitDate)
      AND en.MoveInDate <= pe.report_end
    THEN en.MoveInDate END AS own_move_in
  FROM wchmiscsv.Enrollment en
  JOIN b_b1_projects bp ON en.ProjectID = bp.ProjectID
  LEFT JOIN wchmiscsv.Exit ex ON en.EnrollmentID = ex.EnrollmentID
  CROSS JOIN b_periods pe
),
b_hoh_movein AS (
  SELECT HouseholdID, period, own_move_in AS hoh_move_in_date
  FROM b_own_movein
  WHERE RelationshipToHoH = 1
),
b_effective_movein AS (
  SELECT ov.EnrollmentID, ov.period,
    CASE
      WHEN ov.RelationshipToHoH = 1 THEN ov.own_move_in
      WHEN hm.hoh_move_in_date IS NULL THEN NULL
      WHEN ov.EntryDate <= hm.hoh_move_in_date
           AND (ov.ExitDate IS NULL OR ov.ExitDate >= hm.hoh_move_in_date) THEN hm.hoh_move_in_date
      WHEN ov.EntryDate > hm.hoh_move_in_date THEN ov.EntryDate
      ELSE NULL
    END AS MoveInDate
  FROM b_own_movein ov
  LEFT JOIN b_hoh_movein hm ON hm.HouseholdID = ov.HouseholdID AND hm.period = ov.period
),
b_exits AS (
  SELECT en.PersonalID, en.EnrollmentID, bp.ProjectType, ex.ExitDate, ex.Destination, em.MoveInDate, pe.period, pe.report_end
  FROM wchmiscsv.Enrollment en
  JOIN b_b1_projects bp ON en.ProjectID = bp.ProjectID
  JOIN wchmiscsv.Exit ex ON en.EnrollmentID = ex.EnrollmentID
  CROSS JOIN b_periods pe
  LEFT JOIN b_effective_movein em ON em.EnrollmentID = en.EnrollmentID AND em.period = pe.period
  WHERE ex.ExitDate >= pe.report_start AND ex.ExitDate <= pe.report_end
    AND (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
),
b_still_active AS (
  SELECT DISTINCT en.PersonalID, pe.period
  FROM wchmiscsv.Enrollment en
  JOIN b_b1_projects bp ON en.ProjectID = bp.ProjectID
  LEFT JOIN wchmiscsv.Exit ex ON en.EnrollmentID = ex.EnrollmentID
  CROSS JOIN b_periods pe
  WHERE en.EntryDate <= pe.report_end
    AND (ex.ExitDate IS NULL OR ex.ExitDate > pe.report_end)
    AND (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
),
b_leavers_raw AS (
  SELECT e.*
  FROM b_exits e
  LEFT JOIN b_still_active sa ON sa.PersonalID = e.PersonalID AND sa.period = e.period
  WHERE sa.PersonalID IS NULL
),
b_latest_exit AS (
  SELECT PersonalID, period, ProjectType, ExitDate, Destination, MoveInDate, report_end,
    ROW_NUMBER() OVER (PARTITION BY PersonalID, period ORDER BY ExitDate DESC, EnrollmentID ASC) AS rn
  FROM b_leavers_raw
),
b_move_in_filtered AS (
  SELECT * FROM b_latest_exit
  WHERE rn = 1
    AND NOT (ProjectType IN (3, 9, 10) AND MoveInDate IS NOT NULL AND MoveInDate <= report_end)
),
b_classified AS (
  SELECT
    PersonalID, period,
    CASE
      WHEN Destination BETWEEN 400 AND 499 THEN 'permanent'
      WHEN Destination IN (206, 215, 225, 24) THEN 'exclude'
      ELSE 'neutral'
    END AS bucket
  FROM b_move_in_filtered
),
ph_exits AS (
  SELECT period, PersonalID FROM classified WHERE bucket = 'permanent'
  UNION ALL
  SELECT period, PersonalID FROM b_classified WHERE bucket = 'permanent'
)
SELECT
  COUNT(DISTINCT IF(period = 'Current FY', PersonalID, NULL)) AS current_fy,
  COUNT(DISTINCT IF(period = 'Previous FY', PersonalID, NULL)) AS previous_fy
FROM ph_exits
