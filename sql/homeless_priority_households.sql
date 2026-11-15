-- Hand-written, NOT generated from a wcdash YAML -- see sql/homeless_reach.sql's
-- own header comment for the shared report universe, Active Clients
-- convention, and household-determination machinery this file still
-- reuses (through the `household_members`/`household_ages`/`classified`
-- CTEs) for the page's own Household Type filter. Feeds the Homeless
-- dashboard's Demographics tab Priority Populations QoQ table (Current vs.
-- Previous FY), in long format (one row per period x indicator) -- the
-- page pivots both periods into current/previous/change columns
-- client-side, same convention as sql/homeless_race.sql.
--
-- Per explicit request, this counts PEOPLE who themselves match each
-- characteristic, not households where ANY member matches (the original
-- shape, preserved in git history) -- a household with 2 veterans, for
-- instance, now counts 2 toward "Veterans" instead of 1 toward "Veteran
-- households". The household-level version undercounted exactly this
-- kind of case; the person-level version doesn't, at the cost of losing
-- the "at least one person in this household" framing. Household
-- composition (`household_members`/`household_ages`/`classified`) is
-- still computed -- the page's own Household Type filter is a household-
-- composition concept (adults-only/families-with-children/unaccompanied-
-- minors) independent of this change -- it's just no longer used to
-- aggregate the 4 characteristics themselves; `person_flags` (below)
-- computes those directly per person instead.
--
-- 7 indicators, each a person's own characteristic as of their own
-- representative enrollment's own reference date (the same `rep.EntryDate`
-- used throughout this dashboard for age math and "most recent record as
-- of" lookups):
--   Age 55+               -- the person's own age AS OF THE FISCAL YEAR'S
--                             OWN END DATE (not this file's usual EntryDate
--                             reference date -- see below) is 55 or older.
--                             Per explicit request, following a reported
--                             discrepancy against sql/homeless_age.sql's
--                             own Age distribution table (791 there vs. 743
--                             here, before this change): that table ages
--                             everyone as of the fiscal year's own end date
--                             (its own documented convention), while this
--                             row used to age people as of their own
--                             representative enrollment's EntryDate --
--                             confirmed live the entire 48-person gap
--                             (791 - 743) was exactly the cohort who turned
--                             55 sometime between their own EntryDate and
--                             the fiscal year's end. Switched this row to
--                             period_end to match the Age table instead of
--                             documenting the gap, per explicit choice --
--                             every other row in this file (Disabled,
--                             Co-occurring Disorders, etc.) still uses
--                             EntryDate; this is a one-off exception for
--                             Age 55+ alone, not a dashboard-wide change.
--   Disabled               -- the person's own most recent
--                             Enrollment.DisablingCondition on their
--                             representative enrollment is Yes. Per
--                             explicit request, switched from this row's
--                             original wchmiscsv.Disabilities-table-based
--                             definition (any DisabilityType with
--                             DisabilityResponse = 1) to this single
--                             Enrollment-level field instead -- confirmed
--                             live the two disagree often enough that this
--                             is a genuinely different population, not a
--                             reworded version of the same one (only 537
--                             of the 1,393 people flagged via
--                             DisablingCondition in the current FY are
--                             also flagged via the Disabilities table, and
--                             174 flagged via the table aren't flagged via
--                             DisablingCondition at all) -- this switch
--                             roughly doubled this row's own count (708 ->
--                             1,393 current FY; 490 -> 1,445 previous FY).
--   Persons with Co-occurring
--   Disorders              -- the person's own most recent response is Yes
--                             for BOTH DisabilityType 9 (Mental Health
--                             Disorder) AND DisabilityType 10 (Substance
--                             Use Disorder), each independently evaluated
--                             as of the same reference date -- confirmed
--                             live against wchmiscsv.Disabilities that
--                             these are HUD's current (2024+) 2.07.2 codes
--                             for exactly those two conditions. NOT a
--                             guaranteed subset of "Disabled" above now
--                             that Disabled reads Enrollment.DisablingCondition
--                             directly instead of this same Disabilities
--                             table (it was a guaranteed subset before
--                             that switch) -- confirmed live, 9 of the
--                             current FY's 38 Co-occurring Disorders people
--                             have DisablingCondition != 1 on their own
--                             representative enrollment, so they count
--                             here without counting as Disabled. Relabeled
--                             to "Persons with Co-occurring Disorders," per
--                             explicit request, originally to match
--                             "Persons with HIV/AIDS" below's own naming
--                             convention -- that row has since been
--                             removed (see this file's own history), but
--                             the relabel itself stayed since it reads
--                             fine on its own.
--   Chronically Homeless   -- the person is an adult (18+ as of the
--                             reference date) whose own most recent
--                             DisablingCondition on their representative
--                             enrollment is Yes, AND who is either
--                             continuously homeless 12+ months in their
--                             current episode (Enrollment.DateToStreetESSH,
--                             HUD 3.917's own "approximate date this
--                             episode of homelessness began" -- read
--                             directly rather than re-deriving HUD's own
--                             skip-pattern gate (LOSUnderThreshold /
--                             PreviousStreetESSH), since the instrument
--                             already only populates it when the
--                             continuity question applies: confirmed live,
--                             99.7% of enrollments with a literally-
--                             homeless LivingSituation at entry carry it)
--                             at least 365 days before the reference date,
--                             OR has had 4 or more separate homeless
--                             episodes in the past 3 years cumulatively
--                             totaling 12+ months
--                             (TimesHomelessPastThreeYears = 4 -- HUD's own
--                             top "four or more times" bucket, confirmed
--                             live no higher value appears among real
--                             answers -- AND MonthsHomelessPastThreeYears
--                             IN (112, 113), HUD's own top two codes,
--                             confirmed live these are the highest real-
--                             answer values present and both mean "12
--                             months or more" cumulative). Unlike
--                             Co-occurring Disorders above, this one IS a
--                             guaranteed subset of "Disabled"
--                             above -- both this row and Disabled now read
--                             the same Enrollment.DisablingCondition field
--                             directly, so the DisablingCondition = 1 this
--                             row already requires is exactly what Disabled
--                             itself requires.
--   Veterans               -- the person's own wchmiscsv.Client.VeteranStatus = 1.
--   DV Survivors           -- the person's own most recent
--                             wchmiscsv.HealthAndDV row as of the
--                             reference date has DomesticViolenceSurvivor
--                             = 1, regardless of CurrentlyFleeing --
--                             matches the sibling hmisguru/baltimore
--                             repo's own dashboard.json.py convention for
--                             this same measure ("counts if its set is
--                             anything other than 'No history of domestic
--                             violence reported'").
--   Parenting Youth        -- the person is their own household's Head of
--                             Household (Enrollment.RelationshipToHoH = 1
--                             on their own representative enrollment),
--                             under 25 as of the reference date, AND
--                             either their own most recent
--                             wchmiscsv.HealthAndDV.PregnancyStatus as of
--                             that date is Yes, or their own household
--                             (household_members, below) includes at least
--                             one member under 18 as of that same date --
--                             "has children enrolled with them." Pregnancy
--                             uses its own `pregnancy_latest` lookup (most
--                             recent record where PregnancyStatus is
--                             actually answered), not `dv_latest` -- the
--                             two fields are usually recorded on different
--                             HealthAndDV rows (confirmed live: only 693 of
--                             48,178 rows have both populated), so reusing
--                             dv_latest's own "most recent row overall"
--                             would frequently pick a DV-focused row with a
--                             NULL PregnancyStatus and silently miss an
--                             earlier real answer.
-- Order matches PRIORITY_POPULATIONS_ORDER in src/components/homelessness.js.
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
  SELECT en.EnrollmentID, en.PersonalID, en.HouseholdID, en.EntryDate, en.RelationshipToHoH,
    en.DisablingCondition, en.DateToStreetESSH, en.TimesHomelessPastThreeYears, en.MonthsHomelessPastThreeYears,
    qp.project_type, pe.period, pe.period_end
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
  SELECT PersonalID, period, project_type, HouseholdID, EntryDate, RelationshipToHoH,
    DisablingCondition, DateToStreetESSH, TimesHomelessPastThreeYears, MonthsHomelessPastThreeYears, period_end
  FROM (
    SELECT PersonalID, period, project_type, HouseholdID, EntryDate, RelationshipToHoH,
      DisablingCondition, DateToStreetESSH, TimesHomelessPastThreeYears, MonthsHomelessPastThreeYears, period_end,
      ROW_NUMBER() OVER (PARTITION BY PersonalID, period, project_type ORDER BY EntryDate DESC, EnrollmentID DESC) AS rn
    FROM active_enrollments
  )
  WHERE rn = 1
),
household_members AS (
  SELECT
    r.PersonalID AS rep_person, r.period, r.project_type, r.HouseholdID, r.EntryDate AS ref_date,
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
-- Each person's own most recent Disabilities response PER DISABILITY TYPE
-- as of a reference date, rather than "ever reported any disability" -- a
-- later correction that withdraws an earlier Yes shouldn't still count.
-- DisabilityType is carried through (not just used to partition) so
-- Co-occurring Disorders below can check two specific types independently
-- -- each type's own latest record can be as of a different date. No
-- longer used by "Disabled" itself (see this file's own header), only by
-- Co-occurring Disorders below, which needs two specific DisabilityTypes
-- that Enrollment.DisablingCondition can't give.
disability_latest AS (
  SELECT PersonalID, DisabilityType, DisabilityResponse, InformationDate FROM (
    SELECT PersonalID, DisabilityType, DisabilityResponse, InformationDate,
      ROW_NUMBER() OVER (PARTITION BY PersonalID, DisabilityType ORDER BY InformationDate DESC) AS rn
    FROM wchmiscsv.Disabilities
  )
  WHERE rn = 1
),
dv_latest AS (
  SELECT PersonalID, DomesticViolenceSurvivor, InformationDate FROM (
    SELECT PersonalID, DomesticViolenceSurvivor, InformationDate,
      ROW_NUMBER() OVER (PARTITION BY PersonalID ORDER BY InformationDate DESC) AS rn
    FROM wchmiscsv.HealthAndDV
  )
  WHERE rn = 1
),
-- Each person's own most recent row where PregnancyStatus is actually
-- answered -- NOT the same "most recent row overall" as dv_latest, since
-- Pregnancy and DV are usually recorded on different HealthAndDV rows (see
-- this file's own header on Parenting Youth); filtering to
-- PregnancyStatus IS NOT NULL here keeps a real earlier answer from being
-- shadowed by a later DV-only update.
pregnancy_latest AS (
  SELECT PersonalID, PregnancyStatus, InformationDate FROM (
    SELECT PersonalID, PregnancyStatus, InformationDate,
      ROW_NUMBER() OVER (PARTITION BY PersonalID ORDER BY InformationDate DESC) AS rn
    FROM wchmiscsv.HealthAndDV
    WHERE PregnancyStatus IS NOT NULL
  )
  WHERE rn = 1
),
-- The 7 characteristics, computed per person (the representative person
-- themselves, from `rep` directly) rather than aggregated across their
-- household -- see this file's own header for why.
person_flags AS (
  SELECT
    r.PersonalID, r.period, r.project_type,
    -- Per explicit request, computed as of the fiscal year's own END date
    -- (r.period_end) rather than this file's usual r.EntryDate reference
    -- date -- see this file's own header for why (matches
    -- sql/homeless_age.sql's own age-bucket convention, which ages
    -- everyone as of period_end rather than their own EntryDate).
    CASE
      WHEN cl.DOB IS NULL THEN NULL
      ELSE DATE_DIFF(r.period_end, cl.DOB, YEAR)
        - IF(
            EXTRACT(MONTH FROM cl.DOB) * 100 + EXTRACT(DAY FROM cl.DOB)
              > EXTRACT(MONTH FROM r.period_end) * 100 + EXTRACT(DAY FROM r.period_end),
            1, 0
          )
    END >= 55 AS is_senior,
    cl.VeteranStatus = 1 AS is_veteran,
    -- Per explicit request, reads Enrollment.DisablingCondition directly
    -- rather than the wchmiscsv.Disabilities-table lookup this row
    -- originally used -- see this file's own header for the live-confirmed
    -- disagreement between the two sources.
    r.DisablingCondition = 1 AS is_disabled,
    -- DisabilityType 9 = Mental Health Disorder, 10 = Substance Use
    -- Disorder (HUD 2.07.2) -- two independent EXISTS checks, each
    -- against that type's own latest record as of the reference date,
    -- not a single row that happens to carry both (Disabilities has one
    -- row per type per InformationDate, never both types in one row).
    (EXISTS (
      SELECT 1 FROM disability_latest dl
      WHERE dl.PersonalID = r.PersonalID AND dl.DisabilityType = 9 AND dl.InformationDate <= r.EntryDate AND dl.DisabilityResponse = 1
    ) AND EXISTS (
      SELECT 1 FROM disability_latest dl
      WHERE dl.PersonalID = r.PersonalID AND dl.DisabilityType = 10 AND dl.InformationDate <= r.EntryDate AND dl.DisabilityResponse = 1
    )) AS is_co_occurring,
    -- Adult (18+), their own most recent DisablingCondition = 1, and
    -- either continuously homeless 12+ months in their current episode
    -- (DateToStreetESSH) or 4+ episodes in the past 3 years cumulatively
    -- totaling 12+ months (TimesHomelessPastThreeYears/
    -- MonthsHomelessPastThreeYears) -- see this file's own header for the
    -- full code rationale.
    (
      CASE
        WHEN cl.DOB IS NULL THEN NULL
        ELSE DATE_DIFF(r.EntryDate, cl.DOB, YEAR)
          - IF(
              EXTRACT(MONTH FROM cl.DOB) * 100 + EXTRACT(DAY FROM cl.DOB)
                > EXTRACT(MONTH FROM r.EntryDate) * 100 + EXTRACT(DAY FROM r.EntryDate),
              1, 0
            )
      END >= 18
      AND r.DisablingCondition = 1
      AND (
        (r.DateToStreetESSH IS NOT NULL AND DATE_DIFF(r.EntryDate, r.DateToStreetESSH, DAY) >= 365)
        OR (r.TimesHomelessPastThreeYears = 4 AND r.MonthsHomelessPastThreeYears IN (112, 113))
      )
    ) AS is_chronically_homeless,
    EXISTS (
      SELECT 1 FROM dv_latest dv
      WHERE dv.PersonalID = r.PersonalID AND dv.InformationDate <= r.EntryDate AND dv.DomesticViolenceSurvivor = 1
    ) AS is_dv_survivor,
    -- Head of Household, under 25 as of the reference date, AND (pregnant
    -- OR has a household member under 18 as of that date) -- "children
    -- enrolled with them" reuses household_members' own per-member age
    -- (computed as of this same r.EntryDate), not a separate lookup.
    (
      r.RelationshipToHoH = 1
      AND CASE
        WHEN cl.DOB IS NULL THEN NULL
        ELSE DATE_DIFF(r.EntryDate, cl.DOB, YEAR)
          - IF(
              EXTRACT(MONTH FROM cl.DOB) * 100 + EXTRACT(DAY FROM cl.DOB)
                > EXTRACT(MONTH FROM r.EntryDate) * 100 + EXTRACT(DAY FROM r.EntryDate),
              1, 0
            )
      END < 25
      AND (
        EXISTS (
          SELECT 1 FROM pregnancy_latest pl
          WHERE pl.PersonalID = r.PersonalID AND pl.InformationDate <= r.EntryDate AND pl.PregnancyStatus = 1
        )
        OR EXISTS (
          SELECT 1 FROM household_members hm
          WHERE hm.rep_person = r.PersonalID AND hm.period = r.period AND hm.project_type = r.project_type
            AND hm.age IS NOT NULL AND hm.age < 18
        )
      )
    ) AS is_parenting_youth
  FROM rep r
  JOIN wchmiscsv.Client cl ON cl.PersonalID = r.PersonalID
),
household_ages AS (
  SELECT rep_person, period, project_type, HouseholdID,
    COUNTIF(age IS NOT NULL AND age >= 18) AS adult_cnt,
    COUNTIF(age IS NOT NULL AND age < 18) AS child_cnt
  FROM household_members
  GROUP BY rep_person, period, project_type, HouseholdID
),
classified AS (
  SELECT
    r.PersonalID, r.period, r.project_type, r.HouseholdID,
    CASE
      WHEN ha.adult_cnt > 0 AND ha.child_cnt = 0 THEN 'Adults Only'
      WHEN ha.adult_cnt > 0 AND ha.child_cnt > 0 THEN 'Families with Children'
      WHEN ha.adult_cnt = 0 AND ha.child_cnt > 0 THEN 'Unaccompanied Minors'
      ELSE 'Unknown Household Type'
    END AS household_type
  FROM rep r
  LEFT JOIN household_ages ha ON ha.rep_person = r.PersonalID AND ha.period = r.period AND ha.project_type = r.project_type
),
filtered AS (
  SELECT DISTINCT c.PersonalID, c.period, c.project_type
  FROM classified c
  WHERE ('{{ filters.household_type }}' = 'All Household Types' OR c.household_type = '{{ filters.household_type }}')
),
scoped_flags AS (
  SELECT f.period, pf.PersonalID, pf.is_senior, pf.is_veteran, pf.is_disabled, pf.is_co_occurring, pf.is_chronically_homeless, pf.is_dv_survivor, pf.is_parenting_youth
  FROM filtered f
  JOIN person_flags pf ON pf.PersonalID = f.PersonalID AND pf.period = f.period AND pf.project_type = f.project_type
)
SELECT period, 'Age 55+' AS indicator, COUNT(DISTINCT PersonalID) AS persons FROM scoped_flags WHERE is_senior GROUP BY period
UNION ALL
SELECT period, 'Disabled', COUNT(DISTINCT PersonalID) FROM scoped_flags WHERE is_disabled GROUP BY period
UNION ALL
SELECT period, 'Persons with Co-occurring Disorders', COUNT(DISTINCT PersonalID) FROM scoped_flags WHERE is_co_occurring GROUP BY period
UNION ALL
SELECT period, 'Chronically Homeless', COUNT(DISTINCT PersonalID) FROM scoped_flags WHERE is_chronically_homeless GROUP BY period
UNION ALL
SELECT period, 'Veterans', COUNT(DISTINCT PersonalID) FROM scoped_flags WHERE is_veteran GROUP BY period
UNION ALL
SELECT period, 'DV Survivors', COUNT(DISTINCT PersonalID) FROM scoped_flags WHERE is_dv_survivor GROUP BY period
UNION ALL
SELECT period, 'Parenting Youth', COUNT(DISTINCT PersonalID) FROM scoped_flags WHERE is_parenting_youth GROUP BY period
ORDER BY period, indicator
