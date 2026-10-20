-- Hand-written, NOT generated from a wcdash YAML -- there is no "Coordinated
-- Entry" dashboard in hmisguru/westchester-dac to extract this from, unlike
-- every sql/m*.sql file in this directory. Modeled on the HUD CE APR HMIS
-- Programming Specifications (FY 2026), Q7a/Q8a/Q9a ("Number of Persons
-- Served" / "Number of Households Served" / "Assessment Type"), simplified
-- for a monthly trend dashboard rather than every edge case of the literal
-- spec -- see CLAUDE.md's Coordinated Entry section for what's simplified
-- and why. Regenerate nothing -- edit this file directly if the definition
-- changes.
--
-- Report universe, per the spec: a project counts as Coordinated Entry if it
-- has a CEParticipation record with AccessPoint = 1 overlapping the period,
-- regardless of HMIS ProjectType -- NOT just ProjectType = 14.
--
-- Takes @period_start/@period_end directly (one calendar month at a time),
-- not an implicit "+1 year" window like sql/m*.sql's @report_start.
WITH ce_projects AS (
  SELECT DISTINCT cep.ProjectID
  FROM wchmiscsv.CEParticipation cep
  WHERE cep.AccessPoint = 1
    AND cep.CEParticipationStatusStartDate <= @period_end
    AND (cep.CEParticipationStatusEndDate IS NULL OR cep.CEParticipationStatusEndDate >= @period_start)
),
assessments AS (
  -- One row per CE assessment in the period, at a CE access point project.
  SELECT a.PersonalID, en.HouseholdID, en.ProjectID, a.AssessmentDate
  FROM wchmiscsv.Assessment a
  JOIN wchmiscsv.Enrollment en ON a.EnrollmentID = en.EnrollmentID
  JOIN ce_projects cp ON en.ProjectID = cp.ProjectID
  WHERE a.AssessmentDate >= @period_start AND a.AssessmentDate <= @period_end
    AND (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
),
households AS (
  -- One row per household assessed this period -- its latest assessment
  -- date in-period, if it has more than one (same "latest assessment"
  -- convention the CE APR spec uses, simplified to per-month instead of
  -- per-report-year).
  SELECT HouseholdID, ProjectID, MAX(AssessmentDate) AS assessment_date
  FROM assessments
  GROUP BY HouseholdID, ProjectID
),
household_members AS (
  -- Every household member active (the same "Active Clients" convention
  -- used throughout this repo, e.g. sql/street_outreach_active.sql) as of
  -- their household's own assessment date, with age at that date.
  SELECT DISTINCT
    h.HouseholdID,
    h.ProjectID,
    en2.PersonalID,
    CASE
      WHEN cl.DOB IS NULL THEN NULL
      ELSE DATE_DIFF(h.assessment_date, cl.DOB, YEAR)
        - IF(
            EXTRACT(MONTH FROM cl.DOB) * 100 + EXTRACT(DAY FROM cl.DOB)
              > EXTRACT(MONTH FROM h.assessment_date) * 100 + EXTRACT(DAY FROM h.assessment_date),
            1, 0
          )
    END AS age
  FROM households h
  JOIN wchmiscsv.Enrollment en2 ON en2.HouseholdID = h.HouseholdID AND en2.ProjectID = h.ProjectID
  JOIN wchmiscsv.Client cl ON cl.PersonalID = en2.PersonalID
  LEFT JOIN wchmiscsv.Exit ex2 ON ex2.EnrollmentID = en2.EnrollmentID
  WHERE en2.EntryDate <= h.assessment_date
    AND (ex2.ExitDate IS NULL OR ex2.ExitDate > h.assessment_date)
),
household_ages AS (
  SELECT
    HouseholdID,
    ProjectID,
    COUNTIF(age IS NOT NULL AND age >= 18) AS adult_cnt,
    COUNTIF(age IS NOT NULL AND age < 18) AS child_cnt
  FROM household_members
  GROUP BY HouseholdID, ProjectID
),
household_types AS (
  SELECT
    HouseholdID,
    ProjectID,
    CASE
      WHEN adult_cnt > 0 AND child_cnt = 0 THEN 'Without Children'
      WHEN adult_cnt > 0 AND child_cnt > 0 THEN 'With Children and Adults'
      WHEN adult_cnt = 0 AND child_cnt > 0 THEN 'With Only Children'
      ELSE 'Unknown Household Type'
    END AS household_type
  FROM household_ages
)
SELECT
  ht.household_type AS row_label,
  COUNT(DISTINCT hm.PersonalID) AS persons,
  COUNT(DISTINCT hm.HouseholdID) AS households
FROM household_members hm
JOIN household_types ht ON hm.HouseholdID = ht.HouseholdID AND hm.ProjectID = ht.ProjectID
GROUP BY ht.household_type

UNION ALL

SELECT 'Total' AS row_label, COUNT(DISTINCT hm.PersonalID), COUNT(DISTINCT hm.HouseholdID)
FROM household_members hm
