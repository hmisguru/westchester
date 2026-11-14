-- Hand-written, NOT generated from a wcdash YAML -- modeled on the private
-- hmisguru/westchester-dac repo's own "System Flow and Trend Over Time"
-- widget (`wcshelterutilization.yml`, Westchester Shelter Dashboard), per
-- explicit request extended to cover all 3 of this dashboard's own project
-- types (Street Outreach, Emergency Shelter, Transitional Housing) instead
-- of that source widget's Emergency-Shelter-only scope -- Westchester has
-- no Safe Haven, so there's nothing to drop on that front, same as every
-- other sql/homeless_*.sql file's own qualifying_projects CTE already
-- assumes. Also extended to respect this dashboard's own Project Type and
-- Household Type filters (see sql/homeless_reach.sql's own header for the
-- shared qualifying_projects/household-determination machinery reused
-- here), in place of that source widget's own Singles/Families-only
-- filter.
--
-- "Flow" here means literal entry/exit EVENTS (how many qualifying
-- enrollments started or ended that month) -- unlike every other
-- sql/homeless_*.sql file in this dashboard, which counts DISTINCT
-- PersonalID for an Active Clients SNAPSHOT, this one counts DISTINCT
-- EnrollmentID, since each qualifying enrollment is its own inflow and/or
-- outflow event, not a point-in-time population to dedupe by person. This
-- extends the same "a person active in more than one project type counts
-- once per project type" posture sql/homeless_trend.sql's own header
-- documents: here, a person who both entered and exited a qualifying
-- project this month counts as one inflow event and one outflow event,
-- netting to zero for that month -- the same HUD-SPM-style "number of
-- entries"/"number of exits" convention, not a bug. (This is a different
-- question from the period-OVERLAP "Active Clients" test sql/m3_sheltered.sql's
-- own zero-length-enrollment fix applies elsewhere in this repo, which
-- doesn't apply to counting entry/exit events here.)
--
-- 12 trailing COMPLETE calendar months, ending at the most recently
-- complete month as of the HMIS export's own MAX(ExportEndDate) -- same
-- "most recent complete period" posture as sql/homeless_trend.sql's own 8
-- trailing complete quarters, just month-grained to match the source
-- widget's own calendar-month grain. Unlike that source widget (whose own
-- 12-month window includes the export's own current, possibly-partial
-- month), this excludes the current incomplete month, consistent with
-- every other "over time" chart on this page never showing a partial
-- period as if it were complete.
--
-- Every one of the 12 months is in the output even when its own inflow AND
-- outflow are both genuinely zero (a LEFT JOIN from the canonical `months`
-- list, not a FULL OUTER JOIN of whichever inflow/outflow rows happen to
-- exist, which is what the source widget's own query does and which would
-- silently drop such a month) -- the same zero-row-vs-zero-value gap
-- sql/homeless_trend.sql's own JS-side fix (in renderTrendChart()) patches
-- after the fact; this file avoids the gap in SQL instead, so no
-- equivalent JS-side fill is needed here.
--
-- Household type is determined per QUALIFYING ENROLLMENT (not per
-- person-per-period the way sql/homeless_trend.sql's own `rep` CTE does),
-- since every qualifying enrollment is its own inflow/outflow event here,
-- not a single period's snapshot -- composition is evaluated as of that
-- same enrollment's own EntryDate, the same reference-date convention
-- every other file in this dashboard uses.
--
-- The trend line is the ordinary-least-squares fit over a 0-based month
-- index the source widget's own query already uses (COVAR_SAMP/VAR_SAMP),
-- copied verbatim -- except the fit itself excludes the most recent
-- month (see the `stats` CTE's own comment below for why): its own
-- outflow is routinely undercounted by HMIS exit-reporting lag, and left
-- in would let one likely-incomplete data point single-handedly flip the
-- trend line's direction, confirmed live against real data. The trend
-- line still extends through that last month (extrapolated from the
-- 11-month fit), so the gap between the trend and that month's own bar
-- is visible rather than hidden.
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
bounds AS (
  SELECT
    MIN(month_start) AS window_start,
    DATE_SUB(DATE_ADD(MAX(month_start), INTERVAL 1 MONTH), INTERVAL 1 DAY) AS window_end
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
qualifying_enrollments AS (
  SELECT en.EnrollmentID, en.HouseholdID, en.EntryDate, ex.ExitDate, qp.project_type
  FROM wchmiscsv.Enrollment en, bounds
  JOIN qualifying_projects qp ON en.ProjectID = qp.ProjectID
  LEFT JOIN wchmiscsv.Exit ex ON en.EnrollmentID = ex.EnrollmentID
  WHERE (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
    AND en.EntryDate <= bounds.window_end
    AND (ex.ExitDate IS NULL OR ex.ExitDate >= bounds.window_start)
),
household_members AS (
  SELECT
    qe.EnrollmentID AS rep_enrollment, qe.HouseholdID, qe.EntryDate,
    CASE
      WHEN cl.DOB IS NULL THEN NULL
      ELSE DATE_DIFF(qe.EntryDate, cl.DOB, YEAR)
        - IF(
            EXTRACT(MONTH FROM cl.DOB) * 100 + EXTRACT(DAY FROM cl.DOB)
              > EXTRACT(MONTH FROM qe.EntryDate) * 100 + EXTRACT(DAY FROM qe.EntryDate),
            1, 0
          )
    END AS age
  FROM qualifying_enrollments qe
  JOIN wchmiscsv.Enrollment en2 ON en2.HouseholdID = qe.HouseholdID
  JOIN wchmiscsv.Project p2 ON en2.ProjectID = p2.ProjectID
  JOIN wchmiscsv.Client cl ON cl.PersonalID = en2.PersonalID
  LEFT JOIN wchmiscsv.Exit ex2 ON ex2.EnrollmentID = en2.EnrollmentID
  WHERE en2.EntryDate <= qe.EntryDate
    AND (
      ex2.ExitDate IS NULL
      OR (p2.ProjectType = 4 AND ex2.ExitDate >= qe.EntryDate)
      OR (p2.ProjectType != 4 AND ex2.ExitDate > qe.EntryDate)
    )
),
household_ages AS (
  SELECT rep_enrollment,
    COUNTIF(age IS NOT NULL AND age >= 18) AS adult_cnt,
    COUNTIF(age IS NOT NULL AND age < 18) AS child_cnt
  FROM household_members
  GROUP BY rep_enrollment
),
classified AS (
  SELECT
    qe.EnrollmentID, qe.EntryDate, qe.ExitDate,
    CASE
      WHEN ha.adult_cnt > 0 AND ha.child_cnt = 0 THEN 'Adults Only'
      WHEN ha.adult_cnt > 0 AND ha.child_cnt > 0 THEN 'Families with Children'
      WHEN ha.adult_cnt = 0 AND ha.child_cnt > 0 THEN 'Unaccompanied Minors'
      ELSE 'Unknown Household Type'
    END AS household_type
  FROM qualifying_enrollments qe
  LEFT JOIN household_ages ha ON ha.rep_enrollment = qe.EnrollmentID
),
filtered AS (
  SELECT * FROM classified
  WHERE ('{{ filters.household_type }}' = 'All Household Types' OR household_type = '{{ filters.household_type }}')
),
inflow AS (
  SELECT DATE_TRUNC(EntryDate, MONTH) AS month_start, COUNT(DISTINCT EnrollmentID) AS inflow_count
  FROM filtered, bounds
  WHERE EntryDate BETWEEN bounds.window_start AND bounds.window_end
  GROUP BY month_start
),
outflow AS (
  SELECT DATE_TRUNC(ExitDate, MONTH) AS month_start, COUNT(DISTINCT EnrollmentID) AS outflow_count
  FROM filtered, bounds
  WHERE ExitDate BETWEEN bounds.window_start AND bounds.window_end
  GROUP BY month_start
),
flow_calc AS (
  SELECT
    m.month_start,
    COALESCE(i.inflow_count, 0) AS inflow_count,
    COALESCE(o.outflow_count, 0) AS outflow_count,
    COALESCE(i.inflow_count, 0) - COALESCE(o.outflow_count, 0) AS net_flow
  FROM months m
  LEFT JOIN inflow i ON i.month_start = m.month_start
  LEFT JOIN outflow o ON o.month_start = m.month_start
),
indexed AS (
  SELECT month_start, inflow_count, outflow_count, net_flow,
    ROW_NUMBER() OVER (ORDER BY month_start) - 1 AS x_idx
  FROM flow_calc
),
stats AS (
  -- Excludes the most recent month (MAX(x_idx), the 12th trailing month)
  -- from the trend FIT -- confirmed live against real data that its own
  -- outflow_count is routinely less than half of every other month's,
  -- an HMIS exit-reporting-lag artifact (case managers log exit paperwork
  -- with a delay, so the most recent complete month before any export is
  -- systematically undercounted on exits) rather than a real swing. Left
  -- in that one month's own outflow/net_flow uncorrected for the bars
  -- (still shown as reported, not hidden), but excluded here so this one
  -- likely-incomplete data point can't single-handedly flip the trend
  -- line's own direction -- confirmed live this was happening: the
  -- 12-month fit came out sloping up (+4.5/month) while the 11-month fit
  -- (this CTE's own version) slopes down (-4.3/month), consistent with
  -- the "People/Households Served, Over Time" charts' own declining trend
  -- over the same general period.
  SELECT
    COVAR_SAMP(x_idx, net_flow) AS covar_xy,
    VAR_SAMP(x_idx) AS var_x,
    AVG(x_idx) AS mean_x,
    AVG(net_flow) AS mean_y
  FROM indexed
  WHERE x_idx < (SELECT MAX(x_idx) FROM indexed)
)
SELECT
  FORMAT_DATE('%b %Y', i.month_start) AS period,
  i.inflow_count,
  i.outflow_count,
  i.net_flow,
  s.mean_y + SAFE_DIVIDE(s.covar_xy, s.var_x) * (i.x_idx - s.mean_x) AS trend_value
FROM indexed i
CROSS JOIN stats s
ORDER BY i.month_start
