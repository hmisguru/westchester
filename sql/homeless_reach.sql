-- Hand-written, NOT generated from a wcdash YAML -- there is no DAC dashboard
-- behind Local Measure 3.3 ("People in Street Outreach, Emergency Shelter, or
-- Transitional Housing"), same situation as every sql/ce_*.sql/homeless_*.sql
-- file in this directory. Feeds the Homeless dashboard's Overview tab reach
-- tiles (persons/households active, current vs. previous FY) and the
-- Household Type breakdown. See CLAUDE.md's Homeless dashboard section for
-- the full design rationale.
--
-- Same report universe as sql/street_outreach_active.sql (ES = ProjectType
-- 0/1, TH = ProjectType 2, Street Outreach = ProjectType 4, ContinuumProject
-- = 1), same Active Clients convention (EntryDate <= period_end AND no exit,
-- or exit after period_start; Street Outreach additionally skips the
-- zero-length-enrollment exclusion residential projects get, since a single
-- street contact with no multi-night span is still a legitimate contact).
-- Unlike that file, this one splits ES and TH apart (so Project Type can be
-- filtered to exactly one of the three components) and adds a Household
-- Type breakdown neither the KPI tile nor street_outreach_active.sql compute
-- at all.
--
-- Household type is determined once per person per period, from their own
-- most-recently-started qualifying enrollment that period (ties broken by
-- EnrollmentID) -- the household roster and each member's age are evaluated
-- "as of" that same enrollment's own EntryDate, the same reference-date
-- convention sql/ce_reach.sql uses with assessment_date. A household
-- member's own qualifying-enrollment exit test gets the identical Street
-- Outreach exemption as the active-clients test above (>= rather than >
-- the reference date) -- without it, a same-day Street Outreach contact
-- (EntryDate = ExitDate, legitimate for SO) would fail its own household
-- lookup and silently vanish from every breakdown. Confirmed by testing
-- live: reconciled this file's "All Project Types" x "All Household Types"
-- total to street_outreach_active.sql's own published FY2026 figures
-- exactly (3,961 current FY, 4,354 previous FY) only after adding this
-- exemption.
--
-- A tiny number of people (1 in FY2026, 2 in FY2025, confirmed live) fall
-- into "Unknown Household Type" rather than a real bucket -- not a bug in
-- this query, but a genuine HMIS data irregularity (one enrollment record
-- with an ExitDate recorded before its own EntryDate, so no exit/entry pair
-- validates it as "still active" at any reference date). They stay in the
-- "All Household Types" total (COUNT DISTINCT PersonalID still reconciles
-- exactly) rather than being dropped, which an inner join would have done.
--
-- Households breakdown by household_type can very rarely double-count a
-- household by a handful (confirmed live: 3-4 of ~2,700, both FYs) -- since
-- a household's type is computed per PERSON's own representative enrollment
-- rather than per HOUSEHOLD, two members of the same household whose own
-- "most recently started" enrollment differs can land in different
-- buckets. The Persons breakdown is exact by construction (one row per
-- person); only the Households-by-type split has this tiny overlap. The
-- "All Household Types" selection isn't affected (it counts HouseholdID
-- distinctly without going through per-person classification at all).
WITH bounds AS (
  SELECT
    @report_start AS cur_start,
    DATE_SUB(DATE_ADD(@report_start, INTERVAL 1 YEAR), INTERVAL 1 DAY) AS cur_end,
    DATE_SUB(@report_start, INTERVAL 1 YEAR) AS prev_start,
    DATE_SUB(@report_start, INTERVAL 1 DAY) AS prev_end
),
periods AS (
  SELECT 'Previous FY' AS period, prev_start AS period_start, prev_end AS period_end FROM bounds
  UNION ALL
  SELECT 'Current FY', cur_start, cur_end FROM bounds
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
  SELECT en.EnrollmentID, en.PersonalID, en.HouseholdID, en.EntryDate, qp.project_type, pe.period
  FROM wchmiscsv.Enrollment en
  JOIN qualifying_projects qp ON en.ProjectID = qp.ProjectID
  LEFT JOIN wchmiscsv.Exit ex ON en.EnrollmentID = ex.EnrollmentID
  CROSS JOIN periods pe
  WHERE (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
    AND en.EntryDate <= pe.period_end
    AND (
      ex.ExitDate IS NULL
      OR (qp.project_type = 'Street Outreach' AND ex.ExitDate > pe.period_start)
      OR (qp.project_type != 'Street Outreach' AND ex.ExitDate > pe.period_start AND ex.ExitDate > en.EntryDate)
    )
),
rep AS (
  -- One representative enrollment per (PersonalID, period): whichever
  -- qualifying enrollment started most recently, for determining household
  -- composition. Doesn't affect the headline count (COUNT DISTINCT
  -- PersonalID over active_enrollments already matches the published
  -- figure); this only picks which single enrollment's household to use
  -- for someone active in more than one this period.
  SELECT PersonalID, period, project_type, HouseholdID, EntryDate FROM (
    SELECT PersonalID, period, project_type, HouseholdID, EntryDate,
      ROW_NUMBER() OVER (PARTITION BY PersonalID, period ORDER BY EntryDate DESC, EnrollmentID DESC) AS rn
    FROM active_enrollments
  )
  WHERE rn = 1
),
household_members AS (
  SELECT
    r.PersonalID AS rep_person, r.period, r.HouseholdID,
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
  SELECT rep_person, period, HouseholdID,
    COUNTIF(age IS NOT NULL AND age >= 18) AS adult_cnt,
    COUNTIF(age IS NOT NULL AND age < 18) AS child_cnt
  FROM household_members
  GROUP BY rep_person, period, HouseholdID
),
classified AS (
  SELECT
    r.PersonalID, r.period, r.HouseholdID,
    CASE
      WHEN ha.adult_cnt > 0 AND ha.child_cnt = 0 THEN 'Adults Only'
      WHEN ha.adult_cnt > 0 AND ha.child_cnt > 0 THEN 'Families with Children'
      WHEN ha.adult_cnt = 0 AND ha.child_cnt > 0 THEN 'Unaccompanied Minors'
      ELSE 'Unknown Household Type'
    END AS household_type
  FROM rep r
  LEFT JOIN household_ages ha ON ha.rep_person = r.PersonalID AND ha.period = r.period
)
SELECT period,
  COUNT(DISTINCT PersonalID) AS persons,
  COUNT(DISTINCT HouseholdID) AS households
FROM classified
WHERE ('{{ filters.household_type }}' = 'All Household Types' OR household_type = '{{ filters.household_type }}')
GROUP BY period
