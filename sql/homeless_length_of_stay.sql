-- Hand-written, NOT generated from a wcdash YAML -- feeds the Homeless
-- dashboard's Overview tab "Length of Stay by Project Type" box-and-
-- whisker chart, per explicit request. Same report universe, Active
-- Clients convention, and project-type definitions as every other
-- sql/homeless_*.sql file (see sql/homeless_reach.sql's own header) --
-- Current FY only, since a box plot is a single-snapshot distribution,
-- not a current-vs-previous comparison the way the QoQ tables are (same
-- posture as the Age/Race pies on the Demographics tab, which are also
-- Current FY only).
--
-- One row per person per project type they're active in this FY, using
-- the same per-(PersonalID, project_type) representative-enrollment
-- dedup sql/homeless_sankey.sql's own `rep` CTE already uses, for the
-- same reason: under "All Project Types," a person active in both
-- Street Outreach and Emergency Shelter this FY must contribute to BOTH
-- project types' own boxes, not just whichever enrollment started most
-- recently overall.
--
-- Per an explicit follow-up request, this is scoped to EXITED clients
-- with a COMPLETED stay only -- still-enrolled people (no ExitDate yet)
-- are excluded entirely rather than contributing their stay-so-far
-- through the fiscal year's end, which an earlier version of this chart
-- did (see PR #93/#94 for that shape, and the box's own description/
-- chart notes before this change). `active_enrollments`' own exit test
-- already requires `ExitDate > cur_start`, which is false for a NULL
-- `ExitDate` in BigQuery, so simply dropping the old `ExitDate IS NULL
-- OR` branch below is enough to exclude every still-enrolled enrollment
-- with no extra IS NOT NULL check needed. `length_of_stay_days` is then
-- a plain `DATE_DIFF(ExitDate, EntryDate)` -- no fiscal-year-end cap is
-- needed any more, since every remaining row has a real exit date and
-- a genuinely completed stay. A person whose own exit happened after
-- this fiscal year already closed (the Active Clients test has no upper
-- bound on `ExitDate`) still counts, with their own real, full completed
-- length -- deliberately kept, to stay consistent with the same "Active
-- Clients" population test every other `sql/homeless_*.sql` file in
-- this dashboard reuses unchanged (only the still-enrolled branch was
-- removed, not the population definition itself).
--
-- `GREATEST(..., 0)` in the final SELECT guards against the same genuine
-- HMIS data irregularity sql/homeless_reach.sql's own header documents
-- (an enrollment with its ExitDate recorded before its own EntryDate) --
-- confirmed live, it surfaces here as a single Street Outreach row with
-- a -13-day stay before this floor. Emergency Shelter/Transitional
-- Housing never see it because their own Active Clients test above
-- already requires `ExitDate > EntryDate`; Street Outreach's own test
-- deliberately omits that (a legitimate same-day contact has
-- `ExitDate = EntryDate`), so it alone needs this floor. A floor rather
-- than dropping the row, same "don't drop, correct to a sane value"
-- posture homeless_reach.sql's own header takes for this identical
-- irregularity elsewhere in this dashboard.
WITH bounds AS (
  SELECT
    @report_start AS cur_start,
    DATE_SUB(DATE_ADD(@report_start, INTERVAL 1 YEAR), INTERVAL 1 DAY) AS cur_end
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
active_enrollments AS (
  SELECT en.EnrollmentID, en.PersonalID, en.HouseholdID, en.EntryDate, ex.ExitDate, qp.project_type
  FROM wchmiscsv.Enrollment en
  CROSS JOIN bounds b
  JOIN qualifying_projects qp ON en.ProjectID = qp.ProjectID
  LEFT JOIN wchmiscsv.Exit ex ON en.EnrollmentID = ex.EnrollmentID
  WHERE (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
    AND en.EntryDate <= b.cur_end
    AND (
      (qp.project_type = 'Street Outreach' AND ex.ExitDate > b.cur_start)
      OR (qp.project_type != 'Street Outreach' AND ex.ExitDate > b.cur_start AND ex.ExitDate > en.EntryDate)
    )
),
rep AS (
  SELECT PersonalID, project_type, HouseholdID, EntryDate, ExitDate FROM (
    SELECT PersonalID, project_type, HouseholdID, EntryDate, ExitDate,
      ROW_NUMBER() OVER (PARTITION BY PersonalID, project_type ORDER BY EntryDate DESC, EnrollmentID DESC) AS rn
    FROM active_enrollments
  )
  WHERE rn = 1
),
household_members AS (
  SELECT
    r.PersonalID AS rep_person, r.project_type, r.HouseholdID,
    cl.PersonalID AS member_person,
    CASE
      WHEN cl.DOB IS NULL THEN NULL
      ELSE DATE_DIFF(r.EntryDate, cl.DOB, YEAR)
        - IF(
            EXTRACT(MONTH FROM cl.DOB) * 100 + EXTRACT(DAY FROM cl.DOB)
              > EXTRACT(MONTH FROM r.EntryDate) * 100 + EXTRACT(DAY FROM r.EntryDate),
            1, 0
          )
    END AS age
  FROM rep r
  JOIN wchmiscsv.Enrollment en2 ON en2.HouseholdID = r.HouseholdID
  JOIN wchmiscsv.Project p2 ON en2.ProjectID = p2.ProjectID
  JOIN wchmiscsv.Client cl ON cl.PersonalID = en2.PersonalID
  LEFT JOIN wchmiscsv.Exit ex2 ON ex2.EnrollmentID = en2.EnrollmentID
  WHERE en2.EntryDate <= r.EntryDate
    AND (
      ex2.ExitDate IS NULL
      OR (p2.ProjectType = 4 AND ex2.ExitDate >= r.EntryDate)
      OR (p2.ProjectType != 4 AND ex2.ExitDate > r.EntryDate)
    )
),
household_ages AS (
  SELECT rep_person, project_type, HouseholdID,
    COUNTIF(age IS NOT NULL AND age >= 18) AS adult_cnt,
    COUNTIF(age IS NOT NULL AND age < 18) AS child_cnt
  FROM household_members
  GROUP BY rep_person, project_type, HouseholdID
),
classified AS (
  SELECT
    r.PersonalID, r.project_type, r.EntryDate, r.ExitDate,
    CASE
      WHEN ha.adult_cnt > 0 AND ha.child_cnt = 0 THEN 'Adults Only'
      WHEN ha.adult_cnt > 0 AND ha.child_cnt > 0 THEN 'Families with Children'
      WHEN ha.adult_cnt = 0 AND ha.child_cnt > 0 THEN 'Unaccompanied Minors'
      ELSE 'Unknown Household Type'
    END AS household_type
  FROM rep r
  LEFT JOIN household_ages ha ON ha.rep_person = r.PersonalID AND ha.project_type = r.project_type
)
SELECT
  c.project_type,
  GREATEST(DATE_DIFF(c.ExitDate, c.EntryDate, DAY), 0) AS length_of_stay_days
FROM classified c
WHERE ('{{ filters.household_type }}' = 'All Household Types' OR c.household_type = '{{ filters.household_type }}')
