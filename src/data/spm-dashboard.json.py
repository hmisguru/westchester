"""Observable Framework data loader: full System Performance Dashboard tables.

Unlike spm.json.py (which picks a handful of values for the public KPI
tiles), this loader runs all 9 measure widgets in full and returns every
result row, for a static Observable rendering of the whole dashboard --
modeled on balspm.yml (hmisguru/baltimore-dac, `staging` branch), the same
widget order and "Dashboard Notes" intro text, adapted for Westchester.

CoC-wide only, per explicit choice -- there is no interactive "Fiscal Year
Start Date" or Project filter, just the most recent *complete* federal
fiscal year (Oct 1 - Sep 30) covered by the latest HMIS CSV export, compared
against the fiscal year before it, across every CoC project. A per-project
version of this loader (one scope per individual "active SPM project" --
121 of them as of 2026-10-01, a single-select dropdown on the page) was
built and then archived rather than deleted: see
archive/spm-dashboard.json.py and archive/README.md for the full version
and how to reactivate it.

Credentials: standard Google Application Default Credentials, i.e. the
GOOGLE_APPLICATION_CREDENTIALS env var pointing at a service account key file.
"""

import json
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timezone
from pathlib import Path

from google.cloud import bigquery

BQ_PROJECT_ID = "bruin-508014"
SQL_DIR = Path(__file__).resolve().parents[2] / "sql"

client = bigquery.Client(project=BQ_PROJECT_ID)


# (sql filename, widget name, description, columns) in the same order as
# balspm.yml's own rows. Columns are {name, label, number} straight from
# wcspm.yml's own `columns:` config, so formatting matches the dashboard.
WIDGETS = [
    (
        "m1_length_of_time.sql",
        "Measures 1a and 1b — Average and Median Length of Time Homeless",
        "Average and median length of time (distinct nights) each active client experienced "
        "homelessness, across four universes: 1a.1 (ES-EE, ES-NbN, SH), 1a.2 (+TH), 1b.1 "
        "(ES-EE, ES-NbN, SH, PH -- PH stays only counted when the stay met the "
        "literal-homelessness-at-entry criteria, for nights between project start and "
        "housing move-in), and 1b.2 (+TH). Treat these numbers as directionally useful, not "
        "audit-exact.",
        [
            {"name": "row_label", "label": " "},
            {"name": "universe_persons", "label": "Universe (Persons)", "number": "number"},
            {"name": "avg_lot", "label": "Average LOT Homeless", "number": ".2f"},
            {"name": "median_lot", "label": "Median LOT Homeless", "number": ".2f"},
        ],
    ),
    (
        "m2_returns.sql",
        "Measure 2a/2b — Returns to Homelessness Within 6, 12, and 24 Months",
        "Clients who exited to a permanent housing destination during the 2-year window "
        "ending 730 days before the fiscal year, bucketed by the project type of their "
        "earliest such exit, and whether/when they returned to homelessness within 6, 12, or "
        "24 months. This is a single-period measure (not compared to a prior year) -- the "
        "fiscal year start sets its 2-year lookback window.",
        [
            {"name": "row_bucket", "label": " "},
            {"name": "total_exited", "label": "Total Exited to PH (2yr prior)", "number": "number"},
            {"name": "ret_6", "label": "Returns < 6mo", "number": "number"},
            {"name": "pct_6", "label": "% < 6mo", "number": ".2f"},
            {"name": "ret_12", "label": "Returns 6-12mo", "number": "number"},
            {"name": "pct_12", "label": "% 6-12mo", "number": ".2f"},
            {"name": "ret_24", "label": "Returns 13-24mo", "number": "number"},
            {"name": "pct_24", "label": "% 13-24mo", "number": ".2f"},
            {"name": "total_returns", "label": "Total Returns (2yr)", "number": "number"},
            {"name": "pct_total", "label": "% Total Returns", "number": ".2f"},
        ],
    ),
    (
        "m3_sheltered.sql",
        "Metric 3.2 — Unduplicated Sheltered Persons",
        "Unduplicated counts of clients active in Emergency Shelter (ES-EE and ES-NbN "
        "combined), Safe Haven, and Transitional Housing projects during each fiscal year, "
        "using the \"Active Clients - Method 5: 1+ Nights Active\" methodology. Metric 3.1 "
        "(Point-in-Time counts) is omitted -- per HUD, it is manually entered from separate "
        "PIT submissions, not HMIS-generated.",
        [
            {"name": "bucket", "label": "Project Type"},
            {"name": "current_fy", "label": "Current FY", "number": "number"},
            {"name": "previous_fy", "label": "Previous FY", "number": "number"},
            {"name": "difference", "label": "Difference", "number": "number"},
        ],
    ),
    (
        "m4_income_growth.sql",
        "Metrics 4.1–4.6 — Employment and Income Growth (CoC-Funded Projects)",
        "Adult (18+) clients in CoC Program-funded TH, SH, and PH projects (project types 2, "
        "3, 8, 9, 10, 13; an active grant whose GrantID starts with \"NY\" -- this CoC's own "
        "convention for marking a grant as CoC Program-funded, per explicit choice, since "
        "wchmiscsv.Funder has no standardized Funder source-code field populated the way "
        "balhmiscsv's does). A grant counts as active for a given fiscal year if its date "
        "range overlaps that year (StartDate on or before the year's end, EndDate on or "
        "after the year's start, or no EndDate at all) -- a project can therefore be "
        "in-scope for one fiscal year and not the other if its CoC grant started or ended "
        "between them. System stayers compare their most recent annual assessment to the "
        "one before it; system leavers compare project-exit income to project-start income.",
        [
            {"name": "row_label", "label": " "},
            {"name": "current_fy_universe", "label": "Current FY Universe", "number": "number"},
            {"name": "current_fy_pct", "label": "Current FY % Increased", "number": ".2f"},
            {"name": "previous_fy_universe", "label": "Previous FY Universe", "number": "number"},
            {"name": "previous_fy_pct", "label": "Previous FY % Increased", "number": ".2f"},
            {"name": "pct_difference", "label": "Difference (pp)", "number": ".2f"},
        ],
    ),
    (
        "m5_first_time.sql",
        "Metric 5.1 — First-Time Homeless (ES, SH, TH)",
        "Clients entering ES-EE, ES-NbN, Safe Haven, or Transitional Housing during the "
        "fiscal year with no prior enrollment (looking back up to 24 months) in ES-EE, "
        "ES-NbN, SH, TH, or any PH project.",
        [
            {"name": "row_label", "label": " "},
            {"name": "current_fy", "label": "Current FY", "number": "number"},
            {"name": "previous_fy", "label": "Previous FY", "number": "number"},
            {"name": "difference", "label": "Difference", "number": "number"},
        ],
    ),
    (
        "m5_2_first_time_ph.sql",
        "Metric 5.2 — First-Time Homeless (ES, SH, TH, PH)",
        "Clients entering ES-EE, ES-NbN, Safe Haven, Transitional Housing, or any Permanent "
        "Housing project during the fiscal year with no prior enrollment (same 24-month "
        "lookback) in any of those same project types.",
        [
            {"name": "row_label", "label": " "},
            {"name": "current_fy", "label": "Current FY", "number": "number"},
            {"name": "previous_fy", "label": "Previous FY", "number": "number"},
            {"name": "difference", "label": "Difference", "number": "number"},
        ],
    ),
    (
        "m7a1_street_outreach.sql",
        "Metric 7a.1 — Successful Placement from Street Outreach",
        "Street Outreach leavers (exited SO during the fiscal year and not active in any SO "
        "project as of the fiscal year end) classified by exit destination.",
        [
            {"name": "row_label", "label": " "},
            {"name": "current_fy", "label": "Current FY", "number": "number"},
            {"name": "previous_fy", "label": "Previous FY", "number": "number"},
            {"name": "difference", "label": "Difference", "number": "number"},
        ],
    ),
    (
        "m7b1_placement.sql",
        "Metric 7b.1 — Successful Placement (ES, SH, TH, PH-RRH, PH exits without move-in)",
        "Leavers from ES-EE, ES-NbN, Safe Haven, Transitional Housing, and PH-RRH, plus "
        "leavers from other PH projects who exited without ever moving into housing -- "
        "classified by exit destination. PH exits with a valid housing move-in date are "
        "reported in 7b.2 instead.",
        [
            {"name": "row_label", "label": " "},
            {"name": "current_fy", "label": "Current FY", "number": "number"},
            {"name": "previous_fy", "label": "Previous FY", "number": "number"},
            {"name": "difference", "label": "Difference", "number": "number"},
        ],
    ),
    (
        "m7b2_retention.sql",
        "Metric 7b.2 — Successful Placement/Retention in Permanent Housing",
        "Stayers and leavers in PH-PSH, PH-Housing Only, and PH-Housing Services Only "
        "projects (excludes PH-RRH) with a valid housing move-in date. Stayers who remain "
        "housed always count as successful; leavers are classified by exit destination.",
        [
            {"name": "row_label", "label": " "},
            {"name": "current_fy", "label": "Current FY", "number": "number"},
            {"name": "previous_fy", "label": "Previous FY", "number": "number"},
            {"name": "difference", "label": "Difference", "number": "number"},
        ],
    ),
]


def query(sql, params=()):
    job = client.query(sql, job_config=bigquery.QueryJobConfig(query_parameters=list(params)))
    return [dict(row) for row in job.result()]


def run_measure(filename, report_start):
    """Run one measure query, scoped to every CoC project."""
    return query((SQL_DIR / filename).read_text(), [
        bigquery.ScalarQueryParameter("report_start", "DATE", report_start),
        bigquery.ScalarQueryParameter("all_projects", "BOOL", True),
        bigquery.ArrayQueryParameter("project_ids", "INT64", []),
    ])


def fiscal_year(end_year):
    start, end = date(end_year - 1, 10, 1), date(end_year, 9, 30)
    return {
        "label": f"FY{end_year}",
        "start": start.isoformat(),
        "end": end.isoformat(),
    }


def jsonable(row):
    """Convert BigQuery row values (date/Decimal/etc.) to plain JSON-safe values."""
    out = {}
    for key, value in row.items():
        if hasattr(value, "isoformat"):
            out[key] = value.isoformat()
        elif value is not None and not isinstance(value, (int, float, str, bool)):
            out[key] = float(value)
        else:
            out[key] = value
    return out


def main():
    export_end = query("SELECT MAX(ExportEndDate) AS d FROM wchmiscsv.Export")[0]["d"]
    fy_end_year = export_end.year if export_end >= date(export_end.year, 9, 30) else export_end.year - 1
    current, previous = fiscal_year(fy_end_year), fiscal_year(fy_end_year - 1)
    cur_start = date.fromisoformat(current["start"])

    with ThreadPoolExecutor(max_workers=len(WIDGETS)) as pool:
        futures = {filename: pool.submit(run_measure, filename, cur_start) for filename, _name, _desc, _cols in WIDGETS}
        results = {filename: future.result() for filename, future in futures.items()}

    json.dump(
        {
            "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "export_end": export_end.isoformat(),
            "fiscal_year": current,
            "previous_fiscal_year": previous,
            "source": "Westchester County Continuum of Care (NY-604) HMIS",
            "widgets": [
                {
                    "name": name,
                    "description": description,
                    "columns": columns,
                    "rows": [jsonable(row) for row in results[filename]],
                }
                for filename, name, description, columns in WIDGETS
            ],
        },
        sys.stdout,
        indent=2,
    )


if __name__ == "__main__":
    main()
