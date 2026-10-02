-- Copied from wcspm.yml (hmisguru/westchester-dac, main): "Measures 4.1–4.6 — Employment and Income Growth (CoC-Funded Projects)".
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
universe_projects AS (
  -- CoC Program-funded: an active grant (date range overlapping the fiscal year) whose
  -- GrantID starts with "NY" -- this CoC's own convention for CoC-funded grants, confirmed
  -- live against wchmiscsv.Funder (e.g. "NY01B10-4007"), distinct from non-CoC grant number
  -- formats also present there (e.g. "90CY6591").
  SELECT DISTINCT p.ProjectID, pe.period
  FROM wchmiscsv.Project p
  JOIN wchmiscsv.Funder f ON f.ProjectID = p.ProjectID
  CROSS JOIN periods pe
  WHERE p.ContinuumProject = 1
    AND p.ProjectType IN (2, 3, 8, 9, 10, 13)
    AND f.GrantID LIKE 'NY%'
    AND f.StartDate <= pe.report_end
    AND (f.EndDate IS NULL OR f.EndDate >= pe.report_start)
    AND (@all_projects OR p.ProjectID IN UNNEST(@project_ids))
),
-- ===== System stayers (4.1-4.3) =====
stayer_base AS (
  SELECT en.PersonalID, en.EnrollmentID, en.EntryDate, up.period, pe2.report_end,
    DATE_DIFF(DATE_ADD(pe2.report_end, INTERVAL 1 DAY), en.EntryDate, DAY) AS los_days
  FROM wchmiscsv.Enrollment en
  JOIN universe_projects up ON en.ProjectID = up.ProjectID
  JOIN periods pe2 ON pe2.period = up.period
  LEFT JOIN wchmiscsv.Exit ex ON en.EnrollmentID = ex.EnrollmentID
  WHERE en.EntryDate <= pe2.report_end
    AND (ex.ExitDate IS NULL OR ex.ExitDate > pe2.report_end)
    AND (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
),
stayer_latest AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY PersonalID, period ORDER BY EntryDate DESC, EnrollmentID ASC) AS rn
  FROM stayer_base
  WHERE los_days >= 365
),
stayer_final AS (
  SELECT sl.PersonalID, sl.EnrollmentID, sl.EntryDate, sl.period, sl.report_end
  FROM stayer_latest sl
  JOIN wchmiscsv.Client c ON c.PersonalID = sl.PersonalID
  WHERE sl.rn = 1
    AND DATE_DIFF(sl.EntryDate, c.DOB, YEAR) -
        IF(EXTRACT(MONTH FROM c.DOB) * 100 + EXTRACT(DAY FROM c.DOB)
           > EXTRACT(MONTH FROM sl.EntryDate) * 100 + EXTRACT(DAY FROM sl.EntryDate), 1, 0) >= 18
),
stayer_annual AS (
  SELECT ib.EnrollmentID, ib.InformationDate, ib.TotalMonthlyIncome, ib.EarnedAmount,
    ROW_NUMBER() OVER (PARTITION BY ib.EnrollmentID ORDER BY ib.InformationDate DESC) AS rn
  FROM wchmiscsv.IncomeBenefits ib
  JOIN stayer_final sf ON sf.EnrollmentID = ib.EnrollmentID
  WHERE ib.DataCollectionStage = 5 AND ib.InformationDate <= sf.report_end
),
stayer_later AS (
  SELECT EnrollmentID, TotalMonthlyIncome AS later_total, GREATEST(COALESCE(EarnedAmount, 0), 0) AS later_earned
  FROM stayer_annual WHERE rn = 1
),
stayer_earlier_annual AS (
  SELECT EnrollmentID, TotalMonthlyIncome AS earlier_total, GREATEST(COALESCE(EarnedAmount, 0), 0) AS earlier_earned
  FROM stayer_annual WHERE rn = 2
),
stayer_start_income AS (
  SELECT ib.EnrollmentID, ib.TotalMonthlyIncome AS earlier_total, GREATEST(COALESCE(ib.EarnedAmount, 0), 0) AS earlier_earned
  FROM wchmiscsv.IncomeBenefits ib
  JOIN stayer_final sf ON sf.EnrollmentID = ib.EnrollmentID
  WHERE ib.DataCollectionStage = 1
),
stayer_combined AS (
  SELECT sf.PersonalID, sf.period,
    sl.later_total, sl.later_earned,
    COALESCE(ea.earlier_total, si.earlier_total) AS earlier_total,
    COALESCE(ea.earlier_earned, si.earlier_earned) AS earlier_earned,
    (ea.EnrollmentID IS NOT NULL OR si.EnrollmentID IS NOT NULL) AS has_earlier
  FROM stayer_final sf
  LEFT JOIN stayer_later sl ON sl.EnrollmentID = sf.EnrollmentID
  LEFT JOIN stayer_earlier_annual ea ON ea.EnrollmentID = sf.EnrollmentID
  LEFT JOIN stayer_start_income si ON si.EnrollmentID = sf.EnrollmentID
),
stayer_scored AS (
  SELECT
    PersonalID, period,
    CASE WHEN later_earned IS NOT NULL AND earlier_earned IS NOT NULL AND later_earned > earlier_earned THEN 1 ELSE 0 END AS earned_up,
    CASE WHEN later_total IS NOT NULL AND earlier_total IS NOT NULL
         AND (later_total - later_earned) > (earlier_total - earlier_earned) THEN 1 ELSE 0 END AS nonemp_up,
    CASE WHEN later_total IS NOT NULL AND earlier_total IS NOT NULL AND later_total > earlier_total THEN 1 ELSE 0 END AS total_up
  FROM stayer_combined
  WHERE has_earlier
),
stayer_summary AS (
  SELECT period,
    COUNT(DISTINCT PersonalID) AS universe,
    COUNT(DISTINCT CASE WHEN earned_up = 1 THEN PersonalID END) AS earned_up_cnt,
    COUNT(DISTINCT CASE WHEN nonemp_up = 1 THEN PersonalID END) AS nonemp_up_cnt,
    COUNT(DISTINCT CASE WHEN total_up = 1 THEN PersonalID END) AS total_up_cnt
  FROM stayer_scored
  GROUP BY period
),
-- ===== System leavers (4.4-4.6) =====
leaver_base AS (
  SELECT en.PersonalID, en.EnrollmentID, en.EntryDate, ex.ExitDate, up.period, pe2.report_start, pe2.report_end
  FROM wchmiscsv.Enrollment en
  JOIN universe_projects up ON en.ProjectID = up.ProjectID
  JOIN periods pe2 ON pe2.period = up.period
  JOIN wchmiscsv.Exit ex ON en.EnrollmentID = ex.EnrollmentID
  WHERE ex.ExitDate >= pe2.report_start AND ex.ExitDate <= pe2.report_end
    AND (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
),
leaver_still_active AS (
  SELECT DISTINCT en.PersonalID, up.period
  FROM wchmiscsv.Enrollment en
  JOIN universe_projects up ON en.ProjectID = up.ProjectID
  JOIN periods pe2 ON pe2.period = up.period
  LEFT JOIN wchmiscsv.Exit ex ON en.EnrollmentID = ex.EnrollmentID
  WHERE en.EntryDate <= pe2.report_end
    AND (ex.ExitDate IS NULL OR ex.ExitDate > pe2.report_end)
    AND (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
),
leaver_raw AS (
  SELECT lb.*
  FROM leaver_base lb
  LEFT JOIN leaver_still_active sa ON sa.PersonalID = lb.PersonalID AND sa.period = lb.period
  WHERE sa.PersonalID IS NULL
),
leaver_latest AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY PersonalID, period ORDER BY EntryDate DESC, EnrollmentID ASC) AS rn
  FROM leaver_raw
),
leaver_final AS (
  SELECT ll.PersonalID, ll.EnrollmentID, ll.EntryDate, ll.ExitDate, ll.period
  FROM leaver_latest ll
  JOIN wchmiscsv.Client c ON c.PersonalID = ll.PersonalID
  WHERE ll.rn = 1
    AND DATE_DIFF(ll.EntryDate, c.DOB, YEAR) -
        IF(EXTRACT(MONTH FROM c.DOB) * 100 + EXTRACT(DAY FROM c.DOB)
           > EXTRACT(MONTH FROM ll.EntryDate) * 100 + EXTRACT(DAY FROM ll.EntryDate), 1, 0) >= 18
),
leaver_exit_income AS (
  SELECT ib.EnrollmentID, ib.TotalMonthlyIncome AS later_total, GREATEST(COALESCE(ib.EarnedAmount, 0), 0) AS later_earned
  FROM wchmiscsv.IncomeBenefits ib
  JOIN leaver_final lf ON lf.EnrollmentID = ib.EnrollmentID
  WHERE ib.DataCollectionStage = 3 AND ib.InformationDate = lf.ExitDate
),
leaver_start_income AS (
  SELECT ib.EnrollmentID, ib.TotalMonthlyIncome AS earlier_total, GREATEST(COALESCE(ib.EarnedAmount, 0), 0) AS earlier_earned
  FROM wchmiscsv.IncomeBenefits ib
  JOIN leaver_final lf ON lf.EnrollmentID = ib.EnrollmentID
  WHERE ib.DataCollectionStage = 1 AND ib.InformationDate = lf.EntryDate
),
leaver_combined AS (
  SELECT lf.PersonalID, lf.period,
    lei.later_total, lei.later_earned,
    lsi.earlier_total, lsi.earlier_earned,
    (lsi.EnrollmentID IS NOT NULL) AS has_earlier
  FROM leaver_final lf
  LEFT JOIN leaver_exit_income lei ON lei.EnrollmentID = lf.EnrollmentID
  LEFT JOIN leaver_start_income lsi ON lsi.EnrollmentID = lf.EnrollmentID
),
leaver_scored AS (
  SELECT
    PersonalID, period,
    CASE WHEN later_earned IS NOT NULL AND earlier_earned IS NOT NULL AND later_earned > earlier_earned THEN 1 ELSE 0 END AS earned_up,
    CASE WHEN later_total IS NOT NULL AND earlier_total IS NOT NULL
         AND (later_total - later_earned) > (earlier_total - earlier_earned) THEN 1 ELSE 0 END AS nonemp_up,
    CASE WHEN later_total IS NOT NULL AND earlier_total IS NOT NULL AND later_total > earlier_total THEN 1 ELSE 0 END AS total_up
  FROM leaver_combined
  WHERE has_earlier
),
leaver_summary AS (
  SELECT period,
    COUNT(DISTINCT PersonalID) AS universe,
    COUNT(DISTINCT CASE WHEN earned_up = 1 THEN PersonalID END) AS earned_up_cnt,
    COUNT(DISTINCT CASE WHEN nonemp_up = 1 THEN PersonalID END) AS nonemp_up_cnt,
    COUNT(DISTINCT CASE WHEN total_up = 1 THEN PersonalID END) AS total_up_cnt
  FROM leaver_scored
  GROUP BY period
),
final_rows AS (
  SELECT period, 'Measure 4.1 — Earned income (system stayers)' AS row_label, 1 AS row_order,
    universe, earned_up_cnt AS up_cnt FROM stayer_summary
  UNION ALL
  SELECT period, 'Measure 4.2 — Non-employment income (system stayers)', 2, universe, nonemp_up_cnt FROM stayer_summary
  UNION ALL
  SELECT period, 'Measure 4.3 — Total income (system stayers)', 3, universe, total_up_cnt FROM stayer_summary
  UNION ALL
  SELECT period, 'Measure 4.4 — Earned income (system leavers)', 4, universe, earned_up_cnt FROM leaver_summary
  UNION ALL
  SELECT period, 'Measure 4.5 — Non-employment income (system leavers)', 5, universe, nonemp_up_cnt FROM leaver_summary
  UNION ALL
  SELECT period, 'Measure 4.6 — Total income (system leavers)', 6, universe, total_up_cnt FROM leaver_summary
)
SELECT
  row_label,
  MAX(CASE WHEN period = 'Current FY' THEN universe END) AS current_fy_universe,
  MAX(CASE WHEN period = 'Current FY' THEN up_cnt END) AS current_fy_up_cnt,
  ROUND(SAFE_DIVIDE(MAX(CASE WHEN period = 'Current FY' THEN up_cnt END), MAX(CASE WHEN period = 'Current FY' THEN universe END)) * 100, 2) AS current_fy_pct,
  MAX(CASE WHEN period = 'Previous FY' THEN universe END) AS previous_fy_universe,
  MAX(CASE WHEN period = 'Previous FY' THEN up_cnt END) AS previous_fy_up_cnt,
  ROUND(SAFE_DIVIDE(MAX(CASE WHEN period = 'Previous FY' THEN up_cnt END), MAX(CASE WHEN period = 'Previous FY' THEN universe END)) * 100, 2) AS previous_fy_pct,
  ROUND(SAFE_DIVIDE(MAX(CASE WHEN period = 'Current FY' THEN up_cnt END), MAX(CASE WHEN period = 'Current FY' THEN universe END)) * 100, 2)
    - ROUND(SAFE_DIVIDE(MAX(CASE WHEN period = 'Previous FY' THEN up_cnt END), MAX(CASE WHEN period = 'Previous FY' THEN universe END)) * 100, 2) AS pct_difference
FROM final_rows
GROUP BY row_label, row_order
ORDER BY row_order
