-- Copied from wcspm.yml (hmisguru/westchester-dac, main): "Measures 1a and 1b — Average and Median Length of Time Homeless".
-- Regenerate with scripts/extract_sql.py; do not edit by hand.
WITH bounds AS (
  SELECT
    @report_start AS report_start,
    DATE_SUB(DATE_ADD(@report_start, INTERVAL 1 YEAR), INTERVAL 1 DAY) AS report_end,
    DATE_SUB(@report_start, INTERVAL 7 YEAR) AS lookback_stop
),
qualifying_projects AS (
  SELECT p.ProjectID, p.ProjectType
  FROM wchmiscsv.Project p
  WHERE p.ContinuumProject = 1
    AND p.ProjectType IN (0, 1, 2, 3, 8, 9, 10, 13)
    AND (@all_projects OR p.ProjectID IN UNNEST(@project_ids))
),
entry_criteria_raw AS (
  SELECT
    en.EnrollmentID, en.PersonalID, en.HouseholdID, en.RelationshipToHoH,
    qp.ProjectType, en.EntryDate, ex.ExitDate, en.DateToStreetESSH,
    b.report_start, b.report_end, b.lookback_stop,
    CASE WHEN en.MoveInDate IS NOT NULL
      AND en.MoveInDate >= en.EntryDate
      AND (ex.ExitDate IS NULL OR en.MoveInDate <= ex.ExitDate)
      AND en.MoveInDate <= b.report_end
    THEN en.MoveInDate END AS own_move_in,
    (
      qp.ProjectType IN (0, 1, 8)
      OR (
        qp.ProjectType IN (2, 3, 9, 10, 13)
        AND (
          en.LivingSituation BETWEEN 100 AND 199
          OR (en.LivingSituation BETWEEN 200 AND 299 AND en.LOSUnderThreshold = 1 AND en.PreviousStreetESSH = 1)
          OR ((en.LivingSituation BETWEEN 0 AND 99 OR en.LivingSituation BETWEEN 300 AND 499)
              AND en.LOSUnderThreshold = 1 AND en.PreviousStreetESSH = 1)
        )
      )
    ) AS meets_lh_criteria
  FROM wchmiscsv.Enrollment en
  JOIN qualifying_projects qp ON en.ProjectID = qp.ProjectID
  LEFT JOIN wchmiscsv.Exit ex ON en.EnrollmentID = ex.EnrollmentID
  CROSS JOIN bounds b
  WHERE (en.EnrollmentCoC = 'NY-604' OR en.EnrollmentCoC IS NULL)
),
hoh_movein AS (
  -- Housing move-in date is only required on the Head of Household; inherit it to
  -- other household members per the HMIS Reporting Glossary's "Handling Housing
  -- Move-In Dates" rules.
  SELECT HouseholdID, own_move_in AS hoh_move_in_date
  FROM entry_criteria_raw
  WHERE RelationshipToHoH = 1
),
entry_criteria AS (
  SELECT
    ecr.EnrollmentID, ecr.PersonalID, ecr.ProjectType, ecr.EntryDate, ecr.ExitDate,
    ecr.DateToStreetESSH, ecr.report_start, ecr.report_end, ecr.lookback_stop, ecr.meets_lh_criteria,
    CASE
      WHEN ecr.RelationshipToHoH = 1 THEN ecr.own_move_in
      WHEN hm.hoh_move_in_date IS NULL THEN NULL
      WHEN ecr.EntryDate <= hm.hoh_move_in_date
           AND (ecr.ExitDate IS NULL OR ecr.ExitDate >= hm.hoh_move_in_date) THEN hm.hoh_move_in_date
      WHEN ecr.EntryDate > hm.hoh_move_in_date THEN ecr.EntryDate
      ELSE NULL
    END AS MoveInDate
  FROM entry_criteria_raw ecr
  LEFT JOIN hoh_movein hm ON hm.HouseholdID = ecr.HouseholdID
),
ee_th_sh_nights AS (
  SELECT ec.PersonalID, ec.ProjectType, ec.EnrollmentID, stay_date
  FROM entry_criteria ec,
    UNNEST(GENERATE_DATE_ARRAY(
      GREATEST(ec.EntryDate, ec.lookback_stop),
      LEAST(DATE_SUB(COALESCE(ec.ExitDate, DATE_ADD(ec.report_end, INTERVAL 1 DAY)), INTERVAL 1 DAY), ec.report_end)
    )) AS stay_date
  WHERE ec.ProjectType IN (0, 2, 8)
    AND GREATEST(ec.EntryDate, ec.lookback_stop)
      <= LEAST(DATE_SUB(COALESCE(ec.ExitDate, DATE_ADD(ec.report_end, INTERVAL 1 DAY)), INTERVAL 1 DAY), ec.report_end)
),
nbn_nights AS (
  SELECT ec.PersonalID, ec.ProjectType, ec.EnrollmentID, s.DateProvided AS stay_date
  FROM entry_criteria ec
  JOIN wchmiscsv.Services s ON s.EnrollmentID = ec.EnrollmentID
  WHERE ec.ProjectType = 1
    AND s.RecordType = 200
    AND s.DateProvided >= GREATEST(ec.EntryDate, ec.lookback_stop)
    AND s.DateProvided <= LEAST(COALESCE(DATE_SUB(ec.ExitDate, INTERVAL 1 DAY), ec.report_end), ec.report_end)
),
-- HUD step 5 (Measure 1b only): backdate ES-EE/SH/TH stays that met literal-homelessness-at-entry
-- criteria to their self-reported [approximate date this episode of homelessness started]
-- (element 3.917.3 / DateToStreetESSH), bounded by date of birth per the spec's data-quality guard.
selfreport_eeshth AS (
  SELECT ec.PersonalID, ec.ProjectType, ec.EnrollmentID, stay_date
  FROM entry_criteria ec
  JOIN wchmiscsv.Client c ON c.PersonalID = ec.PersonalID,
    UNNEST(GENERATE_DATE_ARRAY(GREATEST(ec.DateToStreetESSH, c.DOB), ec.EntryDate)) AS stay_date
  WHERE ec.ProjectType IN (0, 2, 8) AND ec.meets_lh_criteria
    AND ec.DateToStreetESSH IS NOT NULL AND ec.DateToStreetESSH <= ec.EntryDate
    AND ec.EntryDate >= ec.lookback_stop
),
-- Same as above for ES-NbN, anchored to the stay's true earliest recorded bed night
-- (not floored at lookback_stop, per HUD step 5b) rather than EntryDate. Derived from
-- nbn_nights itself (rather than re-deriving the entry/exit bounds here) so this CTE can
-- never disagree with nbn_nights about which bed nights belong to the enrollment -- an
-- earlier version bounded its upper end at ExitDate instead of ExitDate - 1, one day more
-- permissive than nbn_nights, which could anchor backdating to a date nbn_nights itself
-- doesn't count as one of the enrollment's nights.
nbn_earliest AS (
  SELECT ec.EnrollmentID, ec.PersonalID, ec.ProjectType, ec.DateToStreetESSH, ec.lookback_stop,
    MIN(nn.stay_date) AS earliest_bed_night
  FROM entry_criteria ec
  JOIN nbn_nights nn ON nn.EnrollmentID = ec.EnrollmentID
  WHERE ec.ProjectType = 1 AND ec.meets_lh_criteria
  GROUP BY ec.EnrollmentID, ec.PersonalID, ec.ProjectType, ec.DateToStreetESSH, ec.lookback_stop
),
selfreport_nbn AS (
  SELECT ne.PersonalID, ne.ProjectType, ne.EnrollmentID, stay_date
  FROM nbn_earliest ne
  JOIN wchmiscsv.Client c ON c.PersonalID = ne.PersonalID,
    UNNEST(GENERATE_DATE_ARRAY(GREATEST(ne.DateToStreetESSH, c.DOB), ne.earliest_bed_night)) AS stay_date
  WHERE ne.DateToStreetESSH IS NOT NULL AND ne.DateToStreetESSH <= ne.earliest_bed_night
    AND ne.earliest_bed_night >= ne.lookback_stop
),
shelter_nights_base AS (
  SELECT * FROM ee_th_sh_nights
  UNION ALL
  SELECT * FROM nbn_nights
),
shelter_nights_1b AS (
  SELECT * FROM shelter_nights_base
  UNION ALL
  SELECT * FROM selfreport_eeshth
  UNION ALL
  SELECT * FROM selfreport_nbn
),
ph_negation AS (
  SELECT PersonalID, MoveInDate AS neg_start, COALESCE(ExitDate, DATE_ADD(report_end, INTERVAL 1 DAY)) AS neg_end
  FROM entry_criteria
  WHERE ProjectType IN (3, 9, 10, 13) AND MoveInDate IS NOT NULL AND MoveInDate <= report_end
),
-- 1a universes never see self-reported data (per HUD spec); 1b universes do -- so TH
-- negation and the flagged-nights pool are each computed twice, once per data source.
th_nights_base AS (
  SELECT DISTINCT PersonalID, stay_date FROM shelter_nights_base WHERE ProjectType = 2
),
th_nights_1b AS (
  SELECT DISTINCT PersonalID, stay_date FROM shelter_nights_1b WHERE ProjectType = 2
),
shelter_nights_flagged_base AS (
  SELECT
    sn.PersonalID, sn.ProjectType, sn.stay_date,
    EXISTS (
      SELECT 1 FROM ph_negation pn
      WHERE pn.PersonalID = sn.PersonalID AND sn.stay_date >= pn.neg_start AND sn.stay_date < pn.neg_end
    ) AS negated_by_ph,
    EXISTS (
      SELECT 1 FROM th_nights_base tn
      WHERE tn.PersonalID = sn.PersonalID AND tn.stay_date = sn.stay_date
    ) AS negated_by_th
  FROM shelter_nights_base sn
),
shelter_nights_flagged_1b AS (
  SELECT
    sn.PersonalID, sn.ProjectType, sn.stay_date,
    EXISTS (
      SELECT 1 FROM ph_negation pn
      WHERE pn.PersonalID = sn.PersonalID AND sn.stay_date >= pn.neg_start AND sn.stay_date < pn.neg_end
    ) AS negated_by_ph,
    EXISTS (
      SELECT 1 FROM th_nights_1b tn
      WHERE tn.PersonalID = sn.PersonalID AND tn.stay_date = sn.stay_date
    ) AS negated_by_th
  FROM shelter_nights_1b sn
),
ph_own_nights AS (
  SELECT ec.PersonalID, ec.ProjectType, stay_date
  FROM entry_criteria ec,
    UNNEST(GENERATE_DATE_ARRAY(
      GREATEST(ec.EntryDate, ec.lookback_stop),
      DATE_SUB(LEAST(ec.MoveInDate, DATE_ADD(ec.report_end, INTERVAL 1 DAY)), INTERVAL 1 DAY)
    )) AS stay_date
  WHERE ec.ProjectType IN (3, 9, 10, 13)
    AND ec.meets_lh_criteria
    AND ec.MoveInDate IS NOT NULL
    AND GREATEST(ec.EntryDate, ec.lookback_stop)
      <= DATE_SUB(LEAST(ec.MoveInDate, DATE_ADD(ec.report_end, INTERVAL 1 DAY)), INTERVAL 1 DAY)
),
-- "Membership" pools (which clients are active / their [client end date]) use ONLY documented
-- bed nights -- never self-reported data -- per HUD's Method 5 universe definition. "Counting"
-- pools (the dataset each client's length-of-time is calculated over) additionally include the
-- 1b self-report backdating. Both pools are unioned across all four rows so the shared
-- client_end/island/client_window pipeline below can run once, partitioned by row_label.
all_membership AS (
  SELECT 'Persons in ES-EE, ES-NbN, and SH' AS row_label, 1 AS row_order, PersonalID, stay_date
  FROM shelter_nights_flagged_base WHERE ProjectType IN (0, 1, 8) AND NOT negated_by_ph AND NOT negated_by_th
  UNION ALL
  SELECT 'Persons in ES-EE, ES-NbN, SH, and TH', 2, PersonalID, stay_date
  FROM shelter_nights_flagged_base WHERE ProjectType IN (0, 1, 2, 8) AND NOT negated_by_ph
  UNION ALL
  SELECT 'Persons in ES-EE, ES-NbN, SH, and PH', 3, PersonalID, stay_date
  FROM shelter_nights_flagged_base WHERE ProjectType IN (0, 1, 8) AND NOT negated_by_ph AND NOT negated_by_th
  UNION ALL
  SELECT 'Persons in ES-EE, ES-NbN, SH, and PH', 3, PersonalID, stay_date FROM ph_own_nights
  UNION ALL
  SELECT 'Persons in ES-EE, ES-NbN, SH, TH, and PH', 4, PersonalID, stay_date
  FROM shelter_nights_flagged_base WHERE ProjectType IN (0, 1, 2, 8) AND NOT negated_by_ph
  UNION ALL
  SELECT 'Persons in ES-EE, ES-NbN, SH, TH, and PH', 4, PersonalID, stay_date FROM ph_own_nights
),
all_counting AS (
  SELECT 'Persons in ES-EE, ES-NbN, and SH' AS row_label, 1 AS row_order, PersonalID, stay_date
  FROM shelter_nights_flagged_base WHERE ProjectType IN (0, 1, 8) AND NOT negated_by_ph AND NOT negated_by_th
  UNION ALL
  SELECT 'Persons in ES-EE, ES-NbN, SH, and TH', 2, PersonalID, stay_date
  FROM shelter_nights_flagged_base WHERE ProjectType IN (0, 1, 2, 8) AND NOT negated_by_ph
  UNION ALL
  SELECT 'Persons in ES-EE, ES-NbN, SH, and PH', 3, PersonalID, stay_date
  FROM shelter_nights_flagged_1b WHERE ProjectType IN (0, 1, 8) AND NOT negated_by_ph AND NOT negated_by_th
  UNION ALL
  SELECT 'Persons in ES-EE, ES-NbN, SH, and PH', 3, PersonalID, stay_date FROM ph_own_nights
  UNION ALL
  SELECT 'Persons in ES-EE, ES-NbN, SH, TH, and PH', 4, PersonalID, stay_date
  FROM shelter_nights_flagged_1b WHERE ProjectType IN (0, 1, 2, 8) AND NOT negated_by_ph
  UNION ALL
  SELECT 'Persons in ES-EE, ES-NbN, SH, TH, and PH', 4, PersonalID, stay_date FROM ph_own_nights
),
bounded_m AS (
  SELECT au.row_label, au.row_order, au.PersonalID, au.stay_date
  FROM all_membership au CROSS JOIN bounds b
  WHERE au.stay_date <= b.report_end
),
bounded_c AS (
  SELECT au.row_label, au.row_order, au.PersonalID, au.stay_date
  FROM all_counting au CROSS JOIN bounds b
  WHERE au.stay_date <= b.report_end
),
client_end AS (
  -- Active Clients Method 5 + HUD step 3: [client end date] must be the client's latest
  -- night that falls WITHIN the report period, not merely before it -- otherwise clients
  -- whose only qualifying nights are years in the past get pulled into the universe.
  SELECT row_label, row_order, PersonalID, MAX(stay_date) AS client_end_date
  FROM bounded_m
  CROSS JOIN bounds b
  WHERE stay_date >= b.report_start
  GROUP BY row_label, row_order, PersonalID
),
-- HUD step 6b: from each client's 365-day anchor, walk backward through any unbroken run of
-- qualifying nights (an "island") to the 7-year lookback stop. Classic gaps-and-islands: a
-- night's distance from its rank within a contiguous run is constant, so grouping on that
-- difference collapses each run to one row.
islands AS (
  SELECT row_label, PersonalID, MIN(stay_date) AS island_min, MAX(stay_date) AS island_max
  FROM (
    SELECT row_label, PersonalID, stay_date,
      DATE_SUB(stay_date, INTERVAL CAST(ROW_NUMBER() OVER (PARTITION BY row_label, PersonalID ORDER BY stay_date) AS INT64) DAY) AS grp
    FROM (
      SELECT DISTINCT bc.row_label, bc.PersonalID, bc.stay_date
      FROM bounded_c bc
      JOIN client_end ce ON ce.row_label = bc.row_label AND ce.PersonalID = bc.PersonalID
      WHERE bc.stay_date <= ce.client_end_date
    )
  )
  GROUP BY row_label, PersonalID, grp
),
client_window AS (
  SELECT ce.row_label, ce.row_order, ce.PersonalID, ce.client_end_date,
    DATE_SUB(ce.client_end_date, INTERVAL 365 DAY) AS client_start_raw,
    b.lookback_stop AS lookback_stop
  FROM client_end ce CROSS JOIN bounds b
),
client_window_extended AS (
  SELECT cw.row_label, cw.row_order, cw.PersonalID, cw.client_end_date,
    CASE WHEN isl.island_min IS NOT NULL THEN GREATEST(isl.island_min, cw.lookback_stop)
         ELSE GREATEST(cw.client_start_raw, cw.lookback_stop) END AS client_start_date
  FROM client_window cw
  LEFT JOIN islands isl ON isl.row_label = cw.row_label AND isl.PersonalID = cw.PersonalID
    -- "adjacent" means the island covers the day before the anchor -- whether it ends there
    -- exactly or straddles it (e.g. a self-report range spanning across the 365-day boundary).
    AND isl.island_min <= DATE_SUB(cw.client_start_raw, INTERVAL 1 DAY)
    AND isl.island_max >= DATE_SUB(cw.client_start_raw, INTERVAL 1 DAY)
),
client_lot AS (
  SELECT
    cw.row_label, cw.row_order, cw.PersonalID,
    COUNT(DISTINCT b.stay_date) AS length_of_time
  FROM client_window_extended cw
  JOIN bounded_c b
    ON b.row_label = cw.row_label AND b.PersonalID = cw.PersonalID
   AND b.stay_date >= cw.client_start_date AND b.stay_date <= cw.client_end_date
  GROUP BY cw.row_label, cw.row_order, cw.PersonalID
)
SELECT
  row_label,
  COUNT(DISTINCT PersonalID) AS universe_persons,
  ROUND(AVG(length_of_time), 2) AS avg_lot,
  ROUND(APPROX_QUANTILES(length_of_time, 2)[OFFSET(1)], 2) AS median_lot
FROM client_lot
GROUP BY row_label, row_order
ORDER BY row_order
