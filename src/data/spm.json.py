"""Observable Framework data loader: HUD System Performance Measure KPIs.

Runs the queries in sql/ against BigQuery at build time and writes one small
JSON document of CoC-wide aggregates to stdout. Nothing row-level ever leaves
BigQuery, and no credentials reach the published site.

There is no project-funding filter here -- every KPI covers all Westchester
CoC projects. (hmisguru/westchester-dac has no `Funder` table, and there's
no funded-project subset to scope to.)

Reports the most recent *complete* federal fiscal year (Oct 1 - Sep 30) covered
by the latest HMIS CSV export, compared against the fiscal year before it.

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


def pick(rows, label_field, label):
    """Return the one row whose label column matches, or fail the build."""
    for row in rows:
        if row[label_field] == label:
            return row
    sys.exit(f"Expected row {label!r} not found in query result: {rows}")


def fiscal_year(end_year):
    start, end = date(end_year - 1, 10, 1), date(end_year, 9, 30)
    return {
        "label": f"FY{end_year}",
        "start": start.isoformat(),
        "end": end.isoformat(),
    }


def build_kpis(results):
    """Turn the measure results into the list of KPI dicts."""
    m1_label = "Persons in ES-EE, ES-NbN, and SH"
    m1_cur = pick(results["m1_cur"], "row_label", m1_label)
    m1_prev = pick(results["m1_prev"], "row_label", m1_label)
    m2_label = "TOTAL Returns to Homelessness"
    m2_cur = pick(results["m2_cur"], "row_bucket", m2_label)
    m2_prev = pick(results["m2_prev"], "row_bucket", m2_label)
    m7_ph = results["m7_ph"][0]
    so_active = results["so_active"][0]
    m4_stayers_total = pick(results["m4"], "row_label", "Measure 4.3 — Total income (system stayers)")
    m5_3 = pick(results["m5_3"], "row_label", "Newly homeless (no prior activity)")
    m7b2_pct = pick(results["m7b2"], "row_label", "% Successful exits/retention")
    m7b2_universe = pick(
        results["m7b2"], "row_label", "Universe: PH-PSH/HO/HS stayers and leavers with move-in"
    )

    kpis = [
        {
            "id": "length-of-time-homeless",
            "measure": "Measure 1a",
            "title": "Average length of time homeless",
            "value": m1_cur["avg_lot"],
            "previous": m1_prev["avg_lot"],
            "format": "days",
            "better": "lower",
            "description": (
                "Average number of nights people in emergency shelter or Safe Haven had "
                "spent homeless, counting back from their last stay in the fiscal year."
            ),
            "universe": m1_cur["universe_persons"],
        },
        {
            "id": "returns-to-homelessness",
            "measure": "Measure 2",
            "title": "Returned to homelessness within 2 years",
            "value": m2_cur["total_returns"],
            "previous": m2_prev["total_returns"],
            "format": "number",
            "unit": "people",
            "better": "lower",
            "description": (
                "People who exited to permanent housing two years before the fiscal year "
                "and came back to shelter, outreach, or housing programs within 24 months."
            ),
            "universe": m2_cur["total_exited"],
        },
        {
            "id": "people-in-street-outreach",
            "eyebrow": "Local Measure 3.3",
            "title": "People in Street Outreach, Emergency Shelter, or Transitional Housing",
            "value": so_active["current_fy"],
            "previous": so_active["previous_fy"],
            "format": "number",
            # Neither direction is inherently better: fewer people found can
            # mean less homelessness, or just less outreach/shelter contact.
            "better": None,
            "description": (
                "Unduplicated people with any Street Outreach, Emergency Shelter, or "
                "Transitional Housing enrollment during the fiscal year. Not an official "
                "HUD System Performance Measure."
            ),
            "universe": None,
        },
        {
            "id": "income-growth-stayers",
            "measure": "Measure 4.3",
            "title": "Stayers with increased total income",
            "value": int(m4_stayers_total["current_fy_up_cnt"]),
            "previous": int(m4_stayers_total["previous_fy_up_cnt"]),
            "format": "number",
            "unit": "people",
            "better": "higher",
            "description": (
                "Adult clients who stayed at least a year in CoC Program-funded transitional, "
                "Safe Haven, or permanent housing programs and saw their total income increase "
                "from one annual assessment to the next."
            ),
            "universe": int(m4_stayers_total["current_fy_universe"]),
        },
        {
            "id": "first-time-homeless-with-outreach",
            "eyebrow": "Local Measure 5.3",
            "title": "People experiencing homelessness for the first time",
            "value": m5_3["current_fy"],
            "previous": m5_3["previous_fy"],
            "format": "number",
            "better": "lower",
            "description": (
                "People entering emergency shelter, Safe Haven, transitional housing, or "
                "Street Outreach with no homeless-system activity (including Street "
                "Outreach contact) in the prior 24 months. Not an official HUD System "
                "Performance Measure."
            ),
            "universe": None,
        },
        {
            "id": "exits-to-permanent-housing",
            "measure": "Measures 7a.1 + 7b.1",
            "title": "Exits to Permanent Destinations",
            "value": m7_ph["current_fy"],
            "previous": m7_ph["previous_fy"],
            "format": "number",
            "unit": "people",
            "better": "higher",
            "description": (
                "People leaving Street Outreach, shelter, Safe Haven, transitional "
                "housing, or rapid re-housing who moved into some form of stable, "
                "permanent housing."
            ),
            "universe": None,
        },
        {
            "id": "permanent-housing-retention",
            "measure": "Measure 7b.2",
            "title": "Permanent Housing Retention",
            "value": m7b2_pct["current_fy"],
            "previous": m7b2_pct["previous_fy"],
            "format": "percent",
            "better": "higher",
            "description": (
                "Percentage of people in Permanent Supportive Housing or other PH "
                "projects who remained housed or exited to another permanent "
                "destination."
            ),
            "universe": int(m7b2_universe["current_fy"]),
        },
    ]
    return kpis


def main():
    export_end = query("SELECT MAX(ExportEndDate) AS d FROM wchmiscsv.Export")[0]["d"]
    fy_end_year = export_end.year if export_end >= date(export_end.year, 9, 30) else export_end.year - 1
    current, previous = fiscal_year(fy_end_year), fiscal_year(fy_end_year - 1)
    cur_start, prev_start = date.fromisoformat(current["start"]), date.fromisoformat(previous["start"])

    # Measures 1 and 2 report a single period, so they run once per fiscal year;
    # the others already return Current FY and Previous FY columns in one pass.
    jobs = {
        "m1_cur": ("m1_length_of_time.sql", cur_start),
        "m1_prev": ("m1_length_of_time.sql", prev_start),
        "m2_cur": ("m2_returns.sql", cur_start),
        "m2_prev": ("m2_returns.sql", prev_start),
        "m4": ("m4_income_growth.sql", cur_start),
        # Non-HUD dashboard addition -- see m5_3_first_time_so.sql's own header
        # comment and CLAUDE.md for why this isn't generated from wcspm.yml
        # like the HUD measures above.
        "m5_3": ("m5_3_first_time_so.sql", cur_start),
        # Measures 7a.1 + 7b.1 permanent-housing exits, each person once
        # (generated by scripts/extract_sql.py from those two measures).
        "m7_ph": ("m7_exits_to_ph.sql", cur_start),
        "m7b2": ("m7b2_retention.sql", cur_start),
        # Non-HUD dashboard addition -- see street_outreach_active.sql's own
        # header comment and CLAUDE.md for why this isn't generated from
        # wcspm.yml like every other file here.
        "so_active": ("street_outreach_active.sql", cur_start),
    }
    with ThreadPoolExecutor(max_workers=len(jobs)) as pool:
        futures = {key: pool.submit(run_measure, filename, start) for key, (filename, start) in jobs.items()}
        results = {key: future.result() for key, future in futures.items()}

    json.dump(
        {
            "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "export_end": export_end.isoformat(),
            "fiscal_year": current,
            "previous_fiscal_year": previous,
            "source": "Westchester County Continuum of Care (NY-604) HMIS",
            "kpis": build_kpis(results),
        },
        sys.stdout,
        indent=2,
    )


if __name__ == "__main__":
    main()
