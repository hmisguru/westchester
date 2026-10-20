-- Hand-written, NOT generated from a wcdash YAML -- same situation as every
-- other sql/ce_*.sql file (no DAC source dashboard exists for Coordinated
-- Entry). Modeled on the HUD CE APR HMIS Programming Specifications (FY
-- 2026), Q10 ("Total Coordinated Entry Activity During the Year") column B
-- ("Total Occurrences"): a raw count of CE Event records by event type, not
-- deduplicated by household or person -- a household referred to both an
-- Emergency Shelter bed opening and post-placement case management in the
-- same month counts once in each row. Regenerate nothing -- edit this file
-- directly if the definition changes.
--
-- Event (4.20.2) response codes, per the spec's own Q9d/Q10 "Data Standards
-- Field and Response" column -- confirmed by reading the spec directly, not
-- assumed from HUD's generic numbering conventions.
--
-- Same report universe and @period_start/@period_end convention as every
-- other file in this directory: ProjectType = 14 projects, one calendar
-- month at a time.
WITH ce_projects AS (
  SELECT p.ProjectID
  FROM wchmiscsv.Project p
  WHERE p.ContinuumProject = 1 AND p.ProjectType = 14
),
events AS (
  SELECT ev.EventID, ev.Event
  FROM wchmiscsv.Event ev
  JOIN wchmiscsv.Enrollment en ON ev.EnrollmentID = en.EnrollmentID
  JOIN ce_projects cp ON en.ProjectID = cp.ProjectID
  WHERE ev.EventDate >= @period_start AND ev.EventDate <= @period_end
    AND (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
)
SELECT
  -- Shortened to fit this dashboard's own horizontal-bar chart labels --
  -- these are this file's own editorial labels, not verbatim HUD Data
  -- Standards response text, so trimming them for legibility is a display
  -- choice, not a factual change. Full response text is in this file's own
  -- header comment reference and the CASE number itself.
  CASE Event
    WHEN 1 THEN 'Referral to Prevention Assistance project'
    WHEN 2 THEN 'Problem Solving/Diversion'
    WHEN 3 THEN 'Referral to CE Crisis Needs Assessment'
    WHEN 4 THEN 'Referral to CE Housing Needs Assessment'
    WHEN 5 THEN 'Referral to post-placement case mgmt'
    WHEN 6 THEN 'Referral to Street Outreach'
    WHEN 7 THEN 'Referral to Housing Navigation'
    WHEN 8 THEN 'Non-continuum services: ineligible'
    WHEN 9 THEN 'Non-continuum services: none available'
    WHEN 10 THEN 'Referral to ES bed opening'
    WHEN 11 THEN 'Referral to TH bed/unit opening'
    WHEN 12 THEN 'Referral to Joint TH-RRH opening'
    WHEN 13 THEN 'Referral to RRH opening'
    WHEN 14 THEN 'Referral to PSH opening'
    WHEN 15 THEN 'Referral to Other PH project'
    WHEN 16 THEN 'Referral to emergency assistance'
    WHEN 17 THEN 'Referral to Housing Voucher (EHV)'
    WHEN 18 THEN 'Referral to a Housing Stability Voucher'
    ELSE 'Unknown'
  END AS row_label,
  COUNT(*) AS events
FROM events
GROUP BY row_label

UNION ALL

SELECT 'Total' AS row_label, COUNT(*) AS events
FROM events
