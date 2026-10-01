"""Observable Framework data loader: HUD System Performance Measure KPIs.

Runs the queries in sql/ against BigQuery at build time and writes one small
JSON document of CoC-wide aggregates to stdout. Nothing row-level ever leaves
BigQuery, and no credentials reach the published site.

Unlike baltimore-kpis, there is no project-funding filter here -- every KPI
covers all Westchester CoC projects. (hmisguru/westchester has no `Funder`
table, and there's no Westchester equivalent of Baltimore's MOHS-funded
subset.)

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


def pick(rows, label_field, label, default=None):
    """Return the one row whose label column matches.

    Falls back to `default` (rather than failing the build) when the query
    returned no rows at all for either fiscal year -- expected for Measure
    7a.1 here, since Westchester has zero Street Outreach (ProjectType 4)
    projects, so its GROUP BY produces no groups rather than a zero-valued
    one. Missing a row when one COULD legitimately exist (`default=None`)
    still fails the build, same as before.
    """
    for row in rows:
        if row[label_field] == label:
            return row
    if default is not None:
        return default
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
    m3 = pick(results["m3"], "bucket", "Total (Unduplicated)")
    m5 = pick(results["m5"], "row_label", "Newly homeless (no prior activity)")
    # Westchester has zero Street Outreach projects, so this query returns no
    # rows at all (not a zero-valued one) -- see pick()'s default= above.
    zero_fy = {"current_fy": 0, "previous_fy": 0}
    m7a_universe = pick(
        results["m7a1"], "row_label", "Universe: persons who exit Street Outreach", default=zero_fy
    )
    m7_ph = results["m7_ph"][0]

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
            "id": "people-sheltered",
            "measure": "Measure 3.2",
            "title": "People in shelter or transitional housing",
            "value": m3["current_fy"],
            "previous": m3["previous_fy"],
            "format": "number",
            # Shown as a neutral change (gray arrow, no Improved/Worsened), per
            # Baltimore's own convention: fewer people sheltered isn't clearly better.
            "better": None,
            "description": (
                "Unduplicated people who stayed in emergency shelter, Safe Haven, or "
                "transitional housing at any point during the fiscal year."
            ),
            "universe": None,
        },
        {
            "id": "first-time-homeless",
            "measure": "Measure 5.1",
            "title": "People experiencing homelessness for the first time",
            "value": m5["current_fy"],
            "previous": m5["previous_fy"],
            "format": "number",
            "better": "lower",
            "description": (
                "People entering emergency shelter, Safe Haven, or transitional housing "
                "with no homeless-system activity in the prior 24 months."
            ),
            "universe": None,
        },
        {
            "id": "street-outreach-exits",
            "measure": "Measure 7a.1",
            "title": "People exiting Street Outreach",
            "value": int(m7a_universe["current_fy"]),
            "previous": int(m7a_universe["previous_fy"]),
            "format": "number",
            "unit": "people",
            # Neither direction is inherently better: fewer exits can mean fewer
            # people needing outreach or less outreach contact.
            "better": None,
            "description": (
                "People who left Street Outreach during the fiscal year, whether to "
                "shelter, housing, or another destination. The Westchester CoC has no "
                "active Street Outreach projects, so this is 0."
            ),
            "universe": int(m7a_universe["current_fy"]),
        },
        {
            "id": "exits-to-permanent-housing",
            "measure": "Measures 7a.1 + 7b.1",
            "title": "Exits to permanent housing",
            "value": m7_ph["current_fy"],
            "previous": m7_ph["previous_fy"],
            "format": "number",
            "unit": "people",
            "better": "higher",
            "description": (
                "People leaving Street Outreach, shelter, Safe Haven, transitional "
                "housing, or rapid re-housing who moved into permanent housing."
            ),
            "universe": None,
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
        "m3": ("m3_sheltered.sql", cur_start),
        "m5": ("m5_first_time.sql", cur_start),
        "m7a1": ("m7a1_street_outreach.sql", cur_start),
        # Measures 7a.1 + 7b.1 permanent-housing exits, each person once
        # (generated by scripts/extract_sql.py from those two measures).
        "m7_ph": ("m7_exits_to_ph.sql", cur_start),
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
