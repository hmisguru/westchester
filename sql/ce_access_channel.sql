-- Hand-written, NOT generated from a wcdash YAML -- same situation as
-- sql/ce_reach.sql (no DAC source dashboard exists for Coordinated Entry).
-- Modeled on the HUD CE APR HMIS Programming Specifications (FY 2026), Q9a
-- ("Assessment Type - Households Assessed in the Date Range"), simplified to
-- a single household-type-blind breakdown (the full spec crosses assessment
-- type with household type; this dashboard's Reach slice already covers the
-- household-type split separately). Regenerate nothing -- edit this file
-- directly if the definition changes.
--
-- Same report universe and @period_start/@period_end convention as
-- sql/ce_reach.sql: CEParticipation.AccessPoint = 1 projects, one calendar
-- month at a time.
WITH ce_projects AS (
  SELECT DISTINCT cep.ProjectID
  FROM wchmiscsv.CEParticipation cep
  WHERE cep.AccessPoint = 1
    AND cep.CEParticipationStatusStartDate <= @period_end
    AND (cep.CEParticipationStatusEndDate IS NULL OR cep.CEParticipationStatusEndDate >= @period_start)
),
assessments AS (
  SELECT en.HouseholdID, en.ProjectID, a.PersonalID, a.AssessmentDate, a.AssessmentType
  FROM wchmiscsv.Assessment a
  JOIN wchmiscsv.Enrollment en ON a.EnrollmentID = en.EnrollmentID
  JOIN ce_projects cp ON en.ProjectID = cp.ProjectID
  WHERE a.AssessmentDate >= @period_start AND a.AssessmentDate <= @period_end
    AND (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
),
latest_per_household AS (
  -- One row per household assessed this period: its own latest assessment's
  -- AssessmentType, same "latest assessment" rule as sql/ce_reach.sql's
  -- `households` CTE. PersonalID as the tiebreaker just makes the pick
  -- deterministic when a household has two same-day assessments.
  SELECT
    HouseholdID,
    ProjectID,
    AssessmentType,
    ROW_NUMBER() OVER (PARTITION BY HouseholdID, ProjectID ORDER BY AssessmentDate DESC, PersonalID) AS rn
  FROM assessments
),
households AS (
  SELECT
    HouseholdID,
    CASE AssessmentType
      WHEN 1 THEN 'Phone'
      WHEN 2 THEN 'Virtual'
      WHEN 3 THEN 'In-Person'
      ELSE 'Unknown'
    END AS channel
  FROM latest_per_household
  WHERE rn = 1
)
SELECT channel AS row_label, COUNT(*) AS households
FROM households
GROUP BY channel

UNION ALL

SELECT 'Total' AS row_label, COUNT(*) AS households
FROM households
