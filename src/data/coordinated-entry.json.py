"""Observable Framework data loader: Coordinated Entry dashboard.

Slices so far: Reach (persons/households assessed, by household type),
Access Channel (phone/virtual/in-person), and Referral Outcomes (a combined
CE Events by Outcome chart -- RRH/PSH/Other PH openings and Prevention
Assistance, each broken down by referral outcome). CE Events originally had
its own Event Mix slice (sql/ce_event_mix.sql, all 18 Event types, by
month); that was later merged into this combined chart per explicit request
and the standalone file removed. The Problem Solving/Diversion and
Residential Success Rate tiles were also removed per explicit request --
this loader computes no rate at all anymore, just the event x outcome
breakdown.

Unlike spm.json.py/dashboard.json.py, this has no DAC YAML source -- the SQL in
sql/ce_*.sql is hand-written against wchmiscsv's own CE data elements
(Assessment 4.19, Event 4.20, CEParticipation 2.09), modeled on the HUD CE APR
HMIS Programming Specifications. See CLAUDE.md's Coordinated Entry section for
what's simplified vs. the literal spec.

Reports the current federal fiscal year (Oct 1 - Sep 30) at MONTHLY
granularity, per explicit request -- unlike every other dashboard on this
site, which compares fiscal-year or quarter-over-quarter periods. Each of the
12 calendar months gets its own query run, so the page can show month-over-
month change and a 12-point trend instead of a single before/after figure.

Credentials: standard Google Application Default Credentials, i.e. the
GOOGLE_APPLICATION_CREDENTIALS env var pointing at a service account key file.
"""

import json
import sys
from calendar import monthrange
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timezone
from pathlib import Path

from google.cloud import bigquery

BQ_PROJECT_ID = "bruin-508014"
SQL_DIR = Path(__file__).resolve().parents[2] / "sql"

client = bigquery.Client(project=BQ_PROJECT_ID)

HOUSEHOLD_TYPES = ["Without Children", "With Children and Adults", "With Only Children", "Unknown Household Type"]
CHANNELS = ["Phone", "Virtual", "In-Person", "Unknown"]
# Per explicit request: these 4 events feed the combined CE Events by
# Outcome chart. Must match the CASE labels in sql/ce_referral_outcomes.sql's
# own event_outcomes CTE exactly.
CHART_EVENTS = [
    "Referral to Prevention Assistance project",
    "Referral to RRH opening",
    "Referral to PSH opening",
    "Referral to Other PH project",
]
CHART_OUTCOMES = ["Successful", "Unsuccessful: client rejected", "Unsuccessful: provider rejected", "No result recorded"]


def query(sql, params=()):
    job = client.query(sql, job_config=bigquery.QueryJobConfig(query_parameters=list(params)))
    return [dict(row) for row in job.result()]


def fiscal_year_months(end_year):
    """The 12 (year, month) pairs of federal fiscal year `end_year`, Oct-Sep."""
    months = [(end_year - 1, m) for m in range(10, 13)] + [(end_year, m) for m in range(1, 10)]
    return months


def run_sql(filename, period_start, period_end):
    """Run one sql/ce_*.sql file for one calendar month."""
    return query((SQL_DIR / filename).read_text(), [
        bigquery.ScalarQueryParameter("period_start", "DATE", period_start),
        bigquery.ScalarQueryParameter("period_end", "DATE", period_end),
    ])


def build_month(period_start, period_end, reach_rows, channel_rows, outcome_rows):
    reach_by_label = {row["row_label"]: row for row in reach_rows}
    total = reach_by_label.get("Total", {"persons": 0, "households": 0})
    channel_by_label = {row["row_label"]: row for row in channel_rows}
    outcome_by_label = {row["row_label"]: row for row in outcome_rows}
    return {
        "label": period_start.strftime("%b %Y"),
        "start": period_start.isoformat(),
        "end": period_end.isoformat(),
        "persons": total["persons"],
        "households": total["households"],
        "by_household_type": [
            {
                "household_type": t,
                "persons": reach_by_label.get(t, {}).get("persons", 0),
                "households": reach_by_label.get(t, {}).get("households", 0),
            }
            for t in HOUSEHOLD_TYPES
        ],
        "by_channel": [
            {"channel": c, "households": channel_by_label.get(c, {}).get("households", 0)}
            for c in CHANNELS
        ],
        "by_event_outcome": [
            {"event": e, "outcome": o, "events": outcome_by_label.get(f"{e} | {o}", {}).get("events", 0)}
            for e in CHART_EVENTS
            for o in CHART_OUTCOMES
        ],
    }


def main():
    export_end = query("SELECT MAX(ExportEndDate) AS d FROM wchmiscsv.Export")[0]["d"]
    fy_end_year = export_end.year if export_end >= date(export_end.year, 9, 30) else export_end.year - 1
    fy_start, fy_end = date(fy_end_year - 1, 10, 1), date(fy_end_year, 9, 30)
    months = fiscal_year_months(fy_end_year)

    # One flat jobs dict across every (month, sql file) pair -- same pattern
    # spm.json.py uses -- rather than nested per-slice thread pools, so adding
    # a future slice's own sql/ce_*.sql file is a one-line addition here.
    periods = {
        (year, month): (date(year, month, 1), date(year, month, monthrange(year, month)[1]))
        for year, month in months
    }
    jobs = {
        (ym, filename): (filename, *periods[ym])
        for ym in months
        for filename in (
            "ce_reach.sql",
            "ce_access_channel.sql",
            "ce_referral_outcomes.sql",
        )
    }
    with ThreadPoolExecutor(max_workers=len(jobs)) as pool:
        futures = {key: pool.submit(run_sql, filename, start, end) for key, (filename, start, end) in jobs.items()}
        results = {key: future.result() for key, future in futures.items()}

    monthly = [
        build_month(
            *periods[ym],
            results[(ym, "ce_reach.sql")],
            results[(ym, "ce_access_channel.sql")],
            results[(ym, "ce_referral_outcomes.sql")],
        )
        for ym in months
    ]
    monthly.sort(key=lambda m: m["start"])

    json.dump(
        {
            "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "export_end": export_end.isoformat(),
            "fiscal_year": {"label": f"FY{fy_end_year}", "start": fy_start.isoformat(), "end": fy_end.isoformat()},
            "source": "Westchester County Continuum of Care (NY-604) HMIS",
            "months": monthly,
        },
        sys.stdout,
        indent=2,
    )


if __name__ == "__main__":
    main()
