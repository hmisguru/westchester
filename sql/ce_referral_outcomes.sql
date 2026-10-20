-- Hand-written, NOT generated from a wcdash YAML -- same situation as every
-- other sql/ce_*.sql file (no DAC source dashboard exists for Coordinated
-- Entry). Modeled on the HUD CE APR HMIS Programming Specifications (FY
-- 2026), Q9c/Q9d/Q10: referral outcomes (Event.ReferralResult, 4.20.D) and
-- the Problem Solving/Diversion/Rapid Resolution success rate
-- (Event.ProbSolDivRRResult, 4.20.A). Regenerate nothing -- edit this file
-- directly if the definition changes.
--
-- Event-type groupings, per the spec's own Q9d row list (confirmed by
-- reading the spec directly):
--   * Referral-outcome universe (Q9d rows 2-15): every Event code EXCEPT
--     Prevention (1), Problem Solving/Diversion (2, has its own separate
--     result field below, not ReferralResult), and the two CE Assessment
--     referrals (3, 4) -- those three never carry a ReferralResult.
--   * Residential-referral universe (Q9d row 23's own formula: "[total
--     successful] / [sum of totals in rows 7 through 12, 14 and 15]"): ES
--     bed opening (10), TH bed/unit opening (11), Joint TH-RRH opening (12),
--     RRH opening (13), PSH opening (14), Other PH project (15), Emergency
--     Housing Voucher (17), and Housing Stability Voucher (18) --
--     deliberately excludes emergency assistance/flex fund (16, row 13 in
--     the spec's own table, not a residential placement) and every
--     non-residential referral type (5, 6, 7, 8, 9).
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
  SELECT ev.EventID, ev.Event, ev.ReferralResult, ev.ProbSolDivRRResult
  FROM wchmiscsv.Event ev
  JOIN wchmiscsv.Enrollment en ON ev.EnrollmentID = en.EnrollmentID
  JOIN ce_projects cp ON en.ProjectID = cp.ProjectID
  WHERE ev.EventDate >= @period_start AND ev.EventDate <= @period_end
    AND (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
),
referrals AS (
  SELECT * FROM events WHERE Event NOT IN (1, 2, 3, 4)
),
residential_referrals AS (
  SELECT * FROM events WHERE Event IN (10, 11, 12, 13, 14, 15, 17, 18)
),
problem_solving AS (
  SELECT * FROM events WHERE Event = 2
)
-- ReferralResult/ProbSolDivRRResult are STRING columns in this dataset (not
-- INT64, confirmed against westchester-dac/refresh_hmis_data.sql's own LOAD
-- DATA schema after a live build failed on this: "No matching signature for
-- operator = for argument types: STRING, INT64") -- compared against string
-- literals below, not the bare integers the HUD response codes are numbered
-- with. A blank string is treated the same as NULL for "no result recorded",
-- since a blank CSV cell can load as either depending on the export.
SELECT 'Successful' AS row_label, COUNT(*) AS events FROM referrals WHERE ReferralResult = '1'
UNION ALL
SELECT 'Unsuccessful: client rejected', COUNT(*) FROM referrals WHERE ReferralResult = '2'
UNION ALL
SELECT 'Unsuccessful: provider rejected', COUNT(*) FROM referrals WHERE ReferralResult = '3'
UNION ALL
SELECT 'No result recorded', COUNT(*) FROM referrals WHERE ReferralResult IS NULL OR ReferralResult = ''
UNION ALL
SELECT 'Residential Successful', COUNT(*) FROM residential_referrals WHERE ReferralResult = '1'
UNION ALL
SELECT 'Residential Total', COUNT(*) FROM residential_referrals
UNION ALL
SELECT 'PSD Successful', COUNT(*) FROM problem_solving WHERE ProbSolDivRRResult = '1'
UNION ALL
SELECT 'PSD Total', COUNT(*) FROM problem_solving
