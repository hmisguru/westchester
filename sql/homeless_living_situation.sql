-- Hand-written, NOT generated from a wcdash YAML -- see sql/homeless_reach.sql's
-- own header comment for the shared report universe, Active Clients
-- convention, and household-determination machinery this file reuses
-- verbatim, scoped to the current FY only (this is a single-snapshot bar
-- chart, same as bridge/dashboard.yml's own "Prior Living Situation by
-- Project Type" widget it's modeled on).
--
-- Prior Living Situation (HUD 3.917, Enrollment.LivingSituation) is read
-- directly off each person's own representative enrollment -- the same one
-- chosen for household-type determination -- bucketed into the same 6
-- categories Bridge's own widget uses, reconstructed from the codes
-- directly since there's no Sheet-provided text label to copy from here
-- (unlike Bridge, which reads `wcdashboard.performance_metrics`'s own
-- pre-bucketed `set` strings). An initial version of this mapping was
-- written from memory against the OLD (pre-2024) 1-37 HUD code list and
-- came back 100% "Other" when tested live -- this CoC's data uses HUD's
-- current unified Living Situation/Destination list instead (hundreds-
-- digit bands: 100s homeless, 200s institutional, 300s temporary, 400s
-- permanent), confirmed via a live GROUP BY against the real codes present
-- (101, 116, 118, 204-207, 215, 225, 302, 314, 329, 332, 335, 336, 410,
-- 411, 421, 435, plus 8/9/99/NULL). Same range convention
-- sql/m7b1_placement.sql's own `Destination BETWEEN 400 AND 499` already
-- uses for this identical HUD code list, just applied to LivingSituation
-- instead of Destination:
--   Street                        -- 116 (place not meant for habitation)
--   Emergency Shelter / Transitional Housing / Safe Haven
--                                 -- 101 (ES), 118 (Safe Haven), 302 (TH)
--   Permanent Setting             -- 400-499 (rental/owned by client, with
--                                    or without subsidy, or staying with
--                                    family/friends on PERMANENT tenure)
--   Institutional Setting         -- 200-299 (psychiatric/substance-abuse/
--                                    medical facility, jail, foster care,
--                                    long-term care)
--   Family or Friends             -- 300-399 except 302 (staying with
--                                    family or friends on TEMPORARY tenure,
--                                    hotel/motel without a voucher, a
--                                    halfway house or other non-homeless-
--                                    criteria residential project)
--   Other                         -- 8, 9, 99, NULL -- don't know/refused/
--                                    data not collected/missing. This is
--                                    the largest bucket in practice (about
--                                    half of all entries, confirmed live)
--                                    since Street Outreach contacts in
--                                    particular often leave this unanswered
--                                    -- not a bug in this query.
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
  SELECT en.EnrollmentID, en.PersonalID, en.HouseholdID, en.EntryDate, en.LivingSituation, qp.project_type
  FROM wchmiscsv.Enrollment en, bounds
  JOIN qualifying_projects qp ON en.ProjectID = qp.ProjectID
  LEFT JOIN wchmiscsv.Exit ex ON en.EnrollmentID = ex.EnrollmentID
  WHERE (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
    AND en.EntryDate <= cur_end
    AND (
      ex.ExitDate IS NULL
      OR (qp.project_type = 'Street Outreach' AND ex.ExitDate > cur_start)
      OR (qp.project_type != 'Street Outreach' AND ex.ExitDate > cur_start AND ex.ExitDate > en.EntryDate)
    )
),
rep AS (
  -- Partitioned by (PersonalID, project_type), not PersonalID alone -- same
  -- correction sql/homeless_trend.sql's own rep CTE already makes for the
  -- identical reason: under "All Project Types", a person active in both
  -- Street Outreach and ES/TH this FY must appear in BOTH project types'
  -- own living-situation breakdown, not get collapsed onto whichever one
  -- happens to have the more recently started enrollment. Confirmed live
  -- this was a real bug, not theoretical -- it undercounted Street
  -- Outreach by 70 people (266 vs. the correct 336) before this fix.
  SELECT PersonalID, project_type, HouseholdID, EntryDate, LivingSituation FROM (
    SELECT PersonalID, project_type, HouseholdID, EntryDate, LivingSituation,
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
    r.PersonalID, r.project_type, r.LivingSituation,
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
  project_type,
  CASE
    WHEN LivingSituation = 116 THEN 'Street'
    WHEN LivingSituation IN (101, 118, 302) THEN 'Emergency Shelter / Transitional Housing'
    WHEN LivingSituation BETWEEN 400 AND 499 THEN 'Permanent Setting'
    WHEN LivingSituation BETWEEN 200 AND 299 THEN 'Institutional Setting'
    WHEN LivingSituation BETWEEN 300 AND 399 THEN 'Family or Friends'
    ELSE 'Other'
  END AS living_situation,
  COUNT(DISTINCT PersonalID) AS persons
FROM classified
WHERE ('{{ filters.household_type }}' = 'All Household Types' OR household_type = '{{ filters.household_type }}')
GROUP BY project_type, living_situation
ORDER BY project_type, living_situation
