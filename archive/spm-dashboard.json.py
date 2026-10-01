"""Observable Framework data loader: full System Performance Dashboard tables.

Unlike spm.json.py (which picks a handful of values for the public KPI
tiles), this loader runs all 9 measure widgets in full and returns every
result row, for a static Observable rendering of the whole dashboard --
modeled on balspm.yml (hmisguru/baltimore-dac, `staging` branch), the same
widget order and "Dashboard Notes" intro text, adapted for Westchester.

Every widget is computed once for all CoC projects (top-level "widgets"),
and once PER PROJECT for every "active SPM project" -- a project with no
OperatingEndDate (still open) and a project type HUD's SPM programming
specs cover (ES-E/E 0, ES-NbN 1, TH 2, PSH 3, SO 4, SH 8, OPH 9 and 10, RRH
13) -- each its own entry under "projects", keyed by ProjectID, per
explicit request for a project-level drill-down (a dropdown of individual
projects, not a single pooled "active projects" scope). Per explicit
choice, this replaces the MOHS-funded-style scope baltimore uses for a
*different* dashboard (Bridge to Housing, HUD LSA-based) -- there is no
Funder table here, and no such grant-funded concept applies to an
SPM-programming-spec dashboard anyway. 121 of wchmiscsv's 179
ContinuumProject=1 projects qualify as of 2026-10-01 (confirmed live): 24
have an OperatingEndDate, 41 are of some other type, with some overlap
between those two exclusions.

This means every one of the 9 widgets runs 122 times (1 CoC-wide + 121
per-project) -- 1,098 BigQuery queries per build. Confirmed acceptable on
2026-10-01: on-demand BigQuery pricing bills by bytes scanned with a 50MB
floor per query, so the added cost of 1,098 queries is a few cents even for
the heaviest widget (Measure 1, ~46MB scanned for one project); the real
constraint is wall-clock build time and BigQuery's concurrent-query
quota, not cost, which is why QUERY_CONCURRENCY below exists.

As in every extracted query (see scripts/extract_sql.py), the Project filter
only narrows the *initial* client universe -- which projects' entries/exits
start someone's inclusion in a measure. Any downstream CoC-wide scan (prior
homelessness history for Measure 5, the search for a return to homelessness
for Measure 2) is NOT narrowed by it and always searches every CoC project,
per the HUD SPM programming specs' own step 5a ("use the same universe of
projects as for the initial selection of data in step 2"). This mirrors the
live DAC dashboard's Project filter behavior exactly -- it's baked into
sql/*.sql itself (UNFILTERED_CTES in extract_sql.py), not something this
loader has to do anything extra for. Each per-project scope here passes
exactly one ProjectID in @project_ids, so a single project is this
measure's whole initial universe; any larger multi-project combination
would require re-running the query (summing precomputed single-project
rows is NOT valid for the several widgets whose per-person dedup logic
spans the whole selected universe at once) -- which is exactly why this is
a single-select dropdown, not a multi-select filter.

Reports the most recent *complete* federal fiscal year (Oct 1 - Sep 30)
covered by the latest HMIS CSV export, compared against the fiscal year
before it -- there is no interactive "Fiscal Year Start Date" control here,
since pre-computing every possible start date isn't practical (same
reasoning the public KPI tiles already use).

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


# HUD SPM programming-spec project types: ES-E/E, ES-NbN, TH, PSH, SO, SH, OPH, RRH.
ACTIVE_SPM_PROJECT_TYPES = [0, 1, 2, 3, 4, 8, 9, 10, 13]

# Caps simultaneous BigQuery query jobs. 1,098 queries (9 widgets x 122
# scopes) all in flight at once would risk BigQuery's per-project concurrent
# query quota; this keeps a steady stream in flight without tripping it.
QUERY_CONCURRENCY = 32


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
        "Metrics 4.1–4.6 — Employment and Income Growth (TH/SH/PH Projects)",
        "Adult (18+) clients in TH, SH, and PH projects, comparing an earlier and later "
        "income data point. Per explicit choice: wchmiscsv has no Funder table, so this is "
        "NOT restricted to CoC Program-funded projects -- the universe here is every "
        "qualifying project type regardless of funding source. System stayers compare their "
        "most recent annual assessment to the one before it; system leavers compare "
        "project-exit income to project-start income.",
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


def run_measure(filename, report_start, project_ids=None):
    """Run one measure query; project_ids=None means every CoC project."""
    return query((SQL_DIR / filename).read_text(), [
        bigquery.ScalarQueryParameter("report_start", "DATE", report_start),
        bigquery.ScalarQueryParameter("all_projects", "BOOL", project_ids is None),
        bigquery.ArrayQueryParameter("project_ids", "INT64", project_ids or []),
    ])


def active_spm_projects():
    """Open (no OperatingEndDate) projects of an HUD SPM-covered type."""
    rows = query("""
        SELECT ProjectID, ProjectName
        FROM wchmiscsv.Project
        WHERE ContinuumProject = 1
          AND OperatingEndDate IS NULL
          AND ProjectType IN UNNEST(@project_types)
        ORDER BY ProjectName
    """, [
        bigquery.ArrayQueryParameter("project_types", "INT64", ACTIVE_SPM_PROJECT_TYPES),
    ])
    if not rows:
        # Publishing all-zero "active projects" figures would be worse than a failed build.
        sys.exit("No active SPM projects found; check Project.OperatingEndDate/ProjectType")
    return rows


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


def build_widgets(results, scope):
    return [
        {
            "name": name,
            "description": description,
            "columns": columns,
            "rows": [jsonable(row) for row in results[(scope, filename)]],
        }
        for filename, name, description, columns in WIDGETS
    ]


def main():
    export_end = query("SELECT MAX(ExportEndDate) AS d FROM wchmiscsv.Export")[0]["d"]
    fy_end_year = export_end.year if export_end >= date(export_end.year, 9, 30) else export_end.year - 1
    current, previous = fiscal_year(fy_end_year), fiscal_year(fy_end_year - 1)
    cur_start = date.fromisoformat(current["start"])

    active_projects = active_spm_projects()
    # "all" (CoC-wide, project_ids=None) plus one scope per individual active project.
    scopes = {"all": None, **{row["ProjectID"]: [row["ProjectID"]] for row in active_projects}}
    print(f"Running {len(WIDGETS)} widgets x {len(scopes)} scopes = {len(WIDGETS) * len(scopes)} queries...", file=sys.stderr)

    with ThreadPoolExecutor(max_workers=QUERY_CONCURRENCY) as pool:
        futures = {
            (scope, filename): pool.submit(run_measure, filename, cur_start, project_ids)
            for scope, project_ids in scopes.items()
            for filename, _name, _desc, _cols in WIDGETS
        }
        results = {key: future.result() for key, future in futures.items()}

    json.dump(
        {
            "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "export_end": export_end.isoformat(),
            "fiscal_year": current,
            "previous_fiscal_year": previous,
            "source": "Westchester County Continuum of Care (NY-604) HMIS",
            "widgets": build_widgets(results, "all"),
            "projects": [
                {
                    "id": row["ProjectID"],
                    "name": row["ProjectName"],
                    "widgets": build_widgets(results, row["ProjectID"]),
                }
                for row in active_projects
            ],
        },
        sys.stdout,
        indent=2,
    )


if __name__ == "__main__":
    main()
