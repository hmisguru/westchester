-- Copied from wcspm.yml (hmisguru/westchester, main): "Measure 2a/2b — Returns to Homelessness Within 6, 12, and 24 Months".
-- Regenerate with scripts/extract_sql.py; do not edit by hand.
WITH bounds AS (
  SELECT
    @report_start AS report_start,
    DATE_SUB(DATE_ADD(@report_start, INTERVAL 1 YEAR), INTERVAL 1 DAY) AS report_end
),
qualifying_projects AS (
  SELECT p.ProjectID, p.ProjectType
  FROM wchmiscsv.Project p
  WHERE p.ContinuumProject = 1
    AND p.ProjectType IN (0, 1, 2, 3, 4, 8, 9, 10, 13)
    AND (@all_projects OR p.ProjectID IN UNNEST(@project_ids))
),
-- Unfiltered CoC-wide pool: per the programming specs' step 5a, the scan for a return
-- to homelessness always covers every relevant project in the CoC, never just the
-- Project filter above (that only narrows who counts as having exited).
coc_projects AS (
  SELECT p.ProjectID, p.ProjectType
  FROM wchmiscsv.Project p
  WHERE p.ContinuumProject = 1
    AND p.ProjectType IN (0, 1, 2, 3, 4, 8, 9, 10, 13)
),
lookback_exits AS (
  SELECT en.PersonalID, en.EnrollmentID, qp.ProjectType, ex.ExitDate, ex.Destination, b.report_end
  FROM wchmiscsv.Enrollment en
  JOIN qualifying_projects qp ON en.ProjectID = qp.ProjectID
  JOIN wchmiscsv.Exit ex ON en.EnrollmentID = ex.EnrollmentID
  CROSS JOIN bounds b
  WHERE ex.ExitDate >= DATE_SUB(b.report_start, INTERVAL 730 DAY)
    AND ex.ExitDate <= DATE_SUB(b.report_end, INTERVAL 730 DAY)
    AND (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
),
ph_exits AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY PersonalID ORDER BY ExitDate ASC, EnrollmentID ASC) AS rn
  FROM lookback_exits
  WHERE Destination BETWEEN 400 AND 499
),
bucketed AS (
  SELECT
    PersonalID, ExitDate, report_end,
    CASE
      WHEN ProjectType = 4 THEN 'Exit was from SO'
      WHEN ProjectType IN (0, 1) THEN 'Exit was from ES'
      WHEN ProjectType = 2 THEN 'Exit was from TH'
      WHEN ProjectType = 8 THEN 'Exit was from SH'
      WHEN ProjectType IN (3, 9, 10, 13) THEN 'Exit was from PH'
    END AS row_bucket
  FROM ph_exits
  WHERE rn = 1
),
candidates AS (
  SELECT en2.PersonalID, en2.EnrollmentID, en2.EntryDate, qp2.ProjectType
  FROM wchmiscsv.Enrollment en2
  JOIN coc_projects qp2 ON en2.ProjectID = qp2.ProjectID
  WHERE (en2.EnrollmentCoC = 'NY-604' OR en2.EnrollmentCoC IS NULL)
),
matches AS (
  SELECT
    b.PersonalID, b.row_bucket, b.ExitDate AS orig_exit,
    MIN(c.EntryDate) AS return_date
  FROM bucketed b
  JOIN candidates c
    ON c.PersonalID = b.PersonalID
   AND c.EntryDate >= b.ExitDate
   AND c.EntryDate <= b.report_end
  WHERE
    c.ProjectType IN (4, 0, 1, 2, 8)
    OR (
      c.ProjectType IN (3, 9, 10, 13)
      AND c.EntryDate > DATE_ADD(b.ExitDate, INTERVAL 14 DAY)
      AND NOT EXISTS (
        SELECT 1
        FROM wchmiscsv.Enrollment en3
        JOIN coc_projects qp3 ON en3.ProjectID = qp3.ProjectID
        LEFT JOIN wchmiscsv.Exit ex3 ON en3.EnrollmentID = ex3.EnrollmentID
        WHERE en3.PersonalID = b.PersonalID
          AND qp3.ProjectType IN (3, 9, 10, 13)
          AND en3.EnrollmentID != c.EnrollmentID
          AND c.EntryDate >= DATE_ADD(en3.EntryDate, INTERVAL 1 DAY)
          AND c.EntryDate <= LEAST(COALESCE(DATE_ADD(ex3.ExitDate, INTERVAL 14 DAY), DATE_ADD(en3.EntryDate, INTERVAL 14 DAY)), b.report_end)
      )
      -- Explicit deviation from the HUD spec: if the client has a still-open PH
      -- enrollment that began within 14 days of this exit (their successful
      -- placement), no later PH enrollment counts as a return, however far outside
      -- the 14-day window it starts -- HUD's spec doesn't account for a client
      -- staying in that same placement under a second, stacked PH subsidy program.
      AND NOT EXISTS (
        SELECT 1
        FROM wchmiscsv.Enrollment en0
        JOIN coc_projects qp0 ON en0.ProjectID = qp0.ProjectID
        LEFT JOIN wchmiscsv.Exit ex0 ON en0.EnrollmentID = ex0.EnrollmentID
        WHERE en0.PersonalID = b.PersonalID
          AND qp0.ProjectType IN (3, 9, 10, 13)
          AND ex0.ExitDate IS NULL
          AND en0.EntryDate <= DATE_ADD(b.ExitDate, INTERVAL 14 DAY)
      )
    )
  GROUP BY b.PersonalID, b.row_bucket, b.ExitDate
),
with_days AS (
  SELECT PersonalID, row_bucket, DATE_DIFF(return_date, orig_exit, DAY) AS days_elapsed
  FROM matches
),
universe_summary AS (
  SELECT row_bucket, COUNT(DISTINCT PersonalID) AS total_exited
  FROM bucketed
  GROUP BY row_bucket
  UNION ALL
  SELECT 'TOTAL Returns to Homelessness', COUNT(DISTINCT PersonalID) FROM bucketed
),
return_summary AS (
  SELECT
    row_bucket,
    COUNT(DISTINCT CASE WHEN days_elapsed BETWEEN 0 AND 180 THEN PersonalID END) AS ret_6,
    COUNT(DISTINCT CASE WHEN days_elapsed BETWEEN 181 AND 365 THEN PersonalID END) AS ret_12,
    COUNT(DISTINCT CASE WHEN days_elapsed BETWEEN 366 AND 730 THEN PersonalID END) AS ret_24
  FROM with_days
  GROUP BY row_bucket
  UNION ALL
  SELECT
    'TOTAL Returns to Homelessness',
    COUNT(DISTINCT CASE WHEN days_elapsed BETWEEN 0 AND 180 THEN PersonalID END),
    COUNT(DISTINCT CASE WHEN days_elapsed BETWEEN 181 AND 365 THEN PersonalID END),
    COUNT(DISTINCT CASE WHEN days_elapsed BETWEEN 366 AND 730 THEN PersonalID END)
  FROM with_days
)
SELECT
  u.row_bucket,
  u.total_exited,
  COALESCE(r.ret_6, 0) AS ret_6,
  ROUND(SAFE_DIVIDE(COALESCE(r.ret_6, 0), u.total_exited) * 100, 2) AS pct_6,
  COALESCE(r.ret_12, 0) AS ret_12,
  ROUND(SAFE_DIVIDE(COALESCE(r.ret_12, 0), u.total_exited) * 100, 2) AS pct_12,
  COALESCE(r.ret_24, 0) AS ret_24,
  ROUND(SAFE_DIVIDE(COALESCE(r.ret_24, 0), u.total_exited) * 100, 2) AS pct_24,
  COALESCE(r.ret_6, 0) + COALESCE(r.ret_12, 0) + COALESCE(r.ret_24, 0) AS total_returns,
  ROUND(SAFE_DIVIDE(COALESCE(r.ret_6, 0) + COALESCE(r.ret_12, 0) + COALESCE(r.ret_24, 0), u.total_exited) * 100, 2) AS pct_total
FROM universe_summary u
LEFT JOIN return_summary r ON r.row_bucket = u.row_bucket
ORDER BY CASE u.row_bucket
  WHEN 'Exit was from SO' THEN 1
  WHEN 'Exit was from ES' THEN 2
  WHEN 'Exit was from TH' THEN 3
  WHEN 'Exit was from SH' THEN 4
  WHEN 'Exit was from PH' THEN 5
  WHEN 'TOTAL Returns to Homelessness' THEN 6
END
