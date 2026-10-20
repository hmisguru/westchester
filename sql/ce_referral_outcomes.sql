-- Hand-written, NOT generated from a wcdash YAML -- same situation as every
-- other sql/ce_*.sql file (no DAC source dashboard exists for Coordinated
-- Entry). Modeled on the HUD CE APR HMIS Programming Specifications (FY
-- 2026), Q9c/Q9d/Q10: referral outcomes (Event.ReferralResult, 4.20.D).
-- Regenerate nothing -- edit this file directly if the definition changes.
--
-- Event-type groupings, per the spec's own Q9d row list (confirmed by
-- reading the spec directly), except where noted below as a deliberate
-- departure:
--   * Residential-referral universe (Q9d row 23's own formula: "[total
--     successful] / [sum of totals in rows 7 through 12, 14 and 15]"): ES
--     bed opening (10), TH bed/unit opening (11), Joint TH-RRH opening (12),
--     RRH opening (13), PSH opening (14), Other PH project (15), Emergency
--     Housing Voucher (17), and Housing Stability Voucher (18) --
--     deliberately excludes emergency assistance/flex fund (16, row 13 in
--     the spec's own table, not a residential placement) and every
--     non-residential referral type (5, 6, 7, 8, 9). Feeds the Referral to
--     Residential Success Rate tile.
--   * Chart event set, per explicit request (and a follow-up correction):
--     RRH opening (13), PSH opening (14), Other PH project (15), and
--     Prevention Assistance (1) -- a deliberate departure from the spec's
--     own Q9d row list, which excludes Prevention from the referral-outcome
--     universe entirely (it's not one of rows 2-15). Feeds the combined CE
--     Events by Outcome chart (event x outcome, stacked).
--
-- Problem Solving/Diversion (Event.ProbSolDivRRResult, 4.20.A) is
-- deliberately NOT computed here -- its own rate tile was removed per
-- explicit request; see CLAUDE.md's Coordinated Entry section.
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
  SELECT ev.EventID, ev.Event, ev.ReferralResult
  FROM wchmiscsv.Event ev
  JOIN wchmiscsv.Enrollment en ON ev.EnrollmentID = en.EnrollmentID
  JOIN ce_projects cp ON en.ProjectID = cp.ProjectID
  WHERE ev.EventDate >= @period_start AND ev.EventDate <= @period_end
    AND (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
),
residential_referrals AS (
  SELECT * FROM events WHERE Event IN (10, 11, 12, 13, 14, 15, 17, 18)
),
event_outcomes AS (
  -- Labels match sql/ce_event_mix.sql's own (now-deleted) shortened CASE
  -- labels for RRH/PSH/Other PH, and EVENT_TYPES' own Prevention label, for
  -- consistency with how this dashboard already names these events.
  SELECT
    CASE Event
      WHEN 1 THEN 'Referral to Prevention Assistance project'
      WHEN 13 THEN 'Referral to RRH opening'
      WHEN 14 THEN 'Referral to PSH opening'
      WHEN 15 THEN 'Referral to Other PH project'
    END AS event_label,
    CASE
      WHEN ReferralResult = '1' THEN 'Successful'
      WHEN ReferralResult = '2' THEN 'Unsuccessful: client rejected'
      WHEN ReferralResult = '3' THEN 'Unsuccessful: provider rejected'
      ELSE 'No result recorded'
    END AS outcome_label
  FROM events
  WHERE Event IN (1, 13, 14, 15)
)
-- ReferralResult is a STRING column in this dataset (not INT64, confirmed
-- against westchester-dac/refresh_hmis_data.sql's own LOAD DATA schema
-- after a live build failed on this: "No matching signature for operator =
-- for argument types: STRING, INT64") -- compared against string literals
-- below, not the bare integers the HUD response codes are numbered with. A
-- blank string is treated the same as NULL for "no result recorded", since
-- a blank CSV cell can load as either depending on the export.
SELECT 'Residential Successful' AS row_label, COUNT(*) AS events FROM residential_referrals WHERE ReferralResult = '1'
UNION ALL
SELECT 'Residential Total', COUNT(*) FROM residential_referrals
UNION ALL
-- One row per (event, outcome) combo actually present this month -- the
-- loader zero-fills any of the 4 x 4 = 16 combos missing here.
SELECT CONCAT(event_label, ' | ', outcome_label) AS row_label, COUNT(*) AS events
FROM event_outcomes
GROUP BY event_label, outcome_label
