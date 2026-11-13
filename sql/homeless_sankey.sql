-- Hand-written, NOT generated from a wcdash YAML -- feeds the Homeless
-- dashboard's Overview tab Sankey chart (Prior Living Situation -> Project
-- Type -> Exit Outcome). Same report universe, Active Clients convention,
-- and household-determination machinery as sql/homeless_living_situation.sql
-- (see that file's own header for the full HUD code-band rationale); reuses
-- that file's exact Prior Living Situation bucketing for the first stage.
--
-- The Exit Outcome stage reads each person's own REPRESENTATIVE
-- enrollment's own Exit record (the same enrollment already chosen for
-- Prior Living Situation and household-type determination), not just any
-- exit during the period -- so a client's full path (entry situation ->
-- project type -> exit outcome) always traces a single consistent
-- enrollment, never mixed across two different stays. A representative
-- enrollment with no Exit row (NULL ExitDate) buckets to 'Still Enrolled'
-- rather than being dropped: the Active Clients population includes people
-- who haven't exited yet, so a third stage limited to "exit destination"
-- alone would make flow leaving each Project Type node smaller than the
-- flow entering it, which reads as a broken diagram rather than a real
-- "most people are still enrolled" finding.
--
-- Exit destination (HUD 3.12) is bucketed into 6 groups by HUD code band,
-- the same BETWEEN-range convention this file's own Prior Living Situation
-- CASE (below) and sql/m7b1_placement.sql's `Destination BETWEEN 400 AND
-- 499` already use:
--   Homeless            -- 100-199 (place not meant for habitation,
--                          emergency shelter, safe haven)
--   Institutional        -- 200-299
--   Temporary Housing     -- 300-399
--   Permanent Housing     -- 400-499
--   Other                 -- 17 (Other), 24 (Deceased) -- a known, recorded
--                            outcome that just isn't a HUD-banded
--                            destination
--   Unknown               -- 8 (don't know), 9 (refused), 30 (no exit
--                            interview completed), 37 (worker unable to
--                            determine), 99 (data not collected), or a
--                            NULL Destination on an enrollment that does
--                            have an Exit row
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
  -- correction/rationale as sql/homeless_living_situation.sql's own rep
  -- CTE: under "All Project Types", a person active in both Street
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
      WHEN LivingSituation IN (101, 118, 302) THEN 'Emergency Shelter / Transitional Housing'
      WHEN LivingSituation BETWEEN 400 AND 499 THEN 'Permanent Setting'
      WHEN LivingSituation BETWEEN 200 AND 299 THEN 'Institutional Setting'
      WHEN LivingSituation BETWEEN 300 AND 399 THEN 'Family or Friends'
      ELSE 'Other'
    END AS source,
    project_type AS target,
    COUNT(DISTINCT PersonalID) AS persons
  FROM filtered
  GROUP BY source, target
),
exit_links AS (
  SELECT
    'exit' AS stage,
    project_type AS source,
    CASE
      WHEN ExitDate IS NULL THEN 'Still Enrolled'
      WHEN Destination BETWEEN 100 AND 199 THEN 'Homeless'
      WHEN Destination BETWEEN 200 AND 299 THEN 'Institutional'
      WHEN Destination BETWEEN 300 AND 399 THEN 'Temporary Housing'
      WHEN Destination BETWEEN 400 AND 499 THEN 'Permanent Housing'
      WHEN Destination IN (17, 24) THEN 'Other'
      ELSE 'Unknown'
    END AS target,
    COUNT(DISTINCT PersonalID) AS persons
  FROM filtered
  GROUP BY source, target
)
SELECT stage, source, target, persons FROM situation_links
UNION ALL
SELECT stage, source, target, persons FROM exit_links
ORDER BY stage, source, target
