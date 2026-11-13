-- Hand-written, NOT generated from a wcdash YAML -- feeds the Homeless
-- dashboard's Overview tab Sankey chart (Prior Living Situation -> Project
-- Type -> Exit Outcome). Same report universe, Active Clients convention,
-- and household-determination machinery as sql/homeless_reach.sql's own
-- header documents; the Prior Living Situation bucketing for the first
-- stage (see the CASE statement below) was originally built for this
-- dashboard's own "Prior Living Situation by Project Type" chart (removed
-- from the Overview tab per explicit request -- see CLAUDE.md's own
-- history of that chart for the full HUD code-band rationale) and copied
-- here rather than re-derived.
--
-- The Exit Outcome stage reads each person's own REPRESENTATIVE
-- enrollment's own Exit record (the same enrollment already chosen for
-- Prior Living Situation and household-type determination), not just any
-- exit during the period -- so a client's full path (entry situation ->
-- project type -> exit outcome) always traces a single consistent
-- enrollment, never mixed across two different stays. A representative
-- enrollment with no Exit row (NULL ExitDate) is still-enrolled --
-- excluded from `exit_links` entirely, per explicit request, rather than
-- flowing to a same-level "Still Enrolled" destination alongside real exit
-- outcomes (an earlier version of this chart did exactly that, as a 7th
-- Exit Outcome node); still-enrolled clients dominated that node (over
-- half of total flow in the real data), squeezing the real destination
-- categories into thin, hard-to-compare ribbons. `renderSankeyChart()` now
-- renders them as a muted, non-flowing cap on each Project Type node
-- itself instead -- see that function's own comment for how.
--
-- Exit destination (HUD 3.12) is bucketed into 6 groups, per explicit
-- request narrower/regrouped than a plain HUD code-band split (the
-- BETWEEN-range convention this file's own Prior Living Situation CASE
-- (below) and sql/m7b1_placement.sql's `Destination BETWEEN 400 AND 499`
-- otherwise use):
--   Street                 -- 116 only (place not meant for habitation) --
--                            narrowed from the full 100-199 band and
--                            relabeled from "Homeless" to "Street" (per a
--                            follow-up explicit request) to read identically
--                            to the left side's own "Street" bucket below,
--                            which is the same HUD code (116); 101 and 118
--                            moved into Emergency & Temporary below
--   Emergency & Temporary  -- 101 (emergency shelter), 118 (Safe Haven),
--                             plus the full 300-399 band (transitional
--                             housing, temporary stays with family/
--                             friends, a paid hotel/motel, a non-homeless-
--                             criteria halfway house, a non-crisis host
--                             home) -- merges what were two separate
--                             buckets (the non-116 part of the old
--                             "Homeless" band, and the old "Temporary
--                             Housing" bucket) into one
--   Institutional          -- 200-299
--   Permanent              -- 400-499
--   Other                  -- 17 (Other), 24 (Deceased) -- a known,
--                             recorded outcome that just isn't a
--                             HUD-banded destination
--   Unknown                -- 8 (don't know), 9 (refused), 30 (no exit
--                             interview completed), 37 (worker unable to
--                             determine), 99 (data not collected), or a
--                             NULL Destination on an enrollment that does
--                             have an Exit row
--
-- Prior Living Situation's own "Emergency & Temporary" and "Friends &
-- Family" buckets (the CASE below) were regrouped and renamed to match
-- this same split, per the same explicit request: "Emergency & Temporary"
-- there is 101, 118, 302 (the old "Emergency Shelter / Transitional
-- Housing" bucket) plus 314, 329, 332 (host home/hotel-motel/halfway
-- house, moved out of the old "Family or Friends" bucket), and "Friends &
-- Family" keeps only 335/336 (staying with family/staying with friends,
-- temporary tenure) -- the two codes the name now literally describes.
-- `renderSankeyChart()`'s own `SANKEY_SIDE_COLORS` gives every matching-named
-- bucket on the two sides (`Street`, `Emergency & Temporary`, `Institutional`/
-- `Institutional Setting`, `Permanent`/`Permanent Setting`, `Other`) the
-- same color, per that same request -- see that constant's own comment.
--
-- Two sets of Sankey links are unioned together, tagged by `stage`:
-- 'situation' links Prior Living Situation -> Project Type, 'exit' links
-- Project Type -> Exit Outcome. Both stages are aggregated from the exact
-- same per-(person, project_type) representative-enrollment rows, so the
-- total flow at each Project Type node reconciles between the two stages
-- by construction -- no separate join or balancing step needed.
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
  SELECT en.EnrollmentID, en.PersonalID, en.HouseholdID, en.EntryDate, en.LivingSituation,
    qp.project_type, ex.ExitDate, ex.Destination
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
  -- One representative enrollment per (PersonalID, project_type), same
  -- correction/rationale as sql/homeless_trend.sql's own rep CTE: under
  -- "All Project Types", a person active in both Street
  -- Outreach and ES/TH this FY must flow through BOTH project types' own
  -- Sankey paths, not get collapsed onto whichever enrollment started most
  -- recently overall.
  SELECT PersonalID, project_type, HouseholdID, EntryDate, LivingSituation, ExitDate, Destination FROM (
    SELECT PersonalID, project_type, HouseholdID, EntryDate, LivingSituation, ExitDate, Destination,
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
    r.PersonalID, r.project_type, r.LivingSituation, r.ExitDate, r.Destination,
    CASE
      WHEN ha.adult_cnt > 0 AND ha.child_cnt = 0 THEN 'Adults Only'
      WHEN ha.adult_cnt > 0 AND ha.child_cnt > 0 THEN 'Families with Children'
      WHEN ha.adult_cnt = 0 AND ha.child_cnt > 0 THEN 'Unaccompanied Minors'
      ELSE 'Unknown Household Type'
    END AS household_type
  FROM rep r
  LEFT JOIN household_ages ha ON ha.rep_person = r.PersonalID AND ha.project_type = r.project_type
),
filtered AS (
  SELECT * FROM classified
  WHERE ('{{ filters.household_type }}' = 'All Household Types' OR household_type = '{{ filters.household_type }}')
),
situation_links AS (
  SELECT
    'situation' AS stage,
    CASE
      WHEN LivingSituation = 116 THEN 'Street'
      WHEN LivingSituation IN (101, 118, 302, 314, 329, 332) THEN 'Emergency & Temporary'
      WHEN LivingSituation BETWEEN 400 AND 499 THEN 'Permanent Setting'
      WHEN LivingSituation BETWEEN 200 AND 299 THEN 'Institutional Setting'
      WHEN LivingSituation BETWEEN 300 AND 399 THEN 'Friends & Family'
      ELSE 'Other'
    END AS source,
    project_type AS target,
    COUNT(DISTINCT PersonalID) AS persons
  FROM filtered
  GROUP BY source, target
),
exit_links AS (
  -- Still-enrolled clients (ExitDate IS NULL) are excluded here entirely,
  -- per explicit request -- they no longer flow to a same-level "Still
  -- Enrolled" destination alongside real exit outcomes. renderSankeyChart()
  -- derives each Project Type node's own still-enrolled count as
  -- node.value minus the sum of its own real exit links (which holds
  -- exactly, since situation_links' own total inflow for a project type
  -- already equals real exits plus still-enrolled by construction -- every
  -- qualifying enrollment is classified into exactly one of those two
  -- buckets) and renders it as a muted, non-flowing cap on that same node,
  -- rather than this file computing or emitting it as its own row.
  SELECT
    'exit' AS stage,
    project_type AS source,
    CASE
      WHEN Destination = 116 THEN 'Street'
      WHEN Destination IN (101, 118) THEN 'Emergency & Temporary'
      WHEN Destination BETWEEN 200 AND 299 THEN 'Institutional'
      WHEN Destination BETWEEN 300 AND 399 THEN 'Emergency & Temporary'
      WHEN Destination BETWEEN 400 AND 499 THEN 'Permanent'
      WHEN Destination IN (17, 24) THEN 'Other'
      ELSE 'Unknown'
    END AS target,
    COUNT(DISTINCT PersonalID) AS persons
  FROM filtered
  WHERE ExitDate IS NOT NULL
  GROUP BY source, target
)
SELECT stage, source, target, persons FROM situation_links
UNION ALL
SELECT stage, source, target, persons FROM exit_links
ORDER BY stage, source, target
