"""Observable Framework data loader: Coordinated Entry dashboard.

Slices so far: Reach (persons/households assessed, by household type) and
Access Channel (phone/virtual/in-person).

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


def build_month(period_start, period_end, reach_rows, channel_rows):
    reach_by_label = {row["row_label"]: row for row in reach_rows}
    total = reach_by_label.get("Total", {"persons": 0, "households": 0})
    channel_by_label = {row["row_label"]: row for row in channel_rows}
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
        for filename in ("ce_reach.sql", "ce_access_channel.sql")
    }
    with ThreadPoolExecutor(max_workers=len(jobs)) as pool:
        futures = {key: pool.submit(run_sql, filename, start, end) for key, (filename, start, end) in jobs.items()}
        results = {key: future.result() for key, future in futures.items()}

    monthly = [
        build_month(*periods[ym], results[(ym, "ce_reach.sql")], results[(ym, "ce_access_channel.sql")])
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
