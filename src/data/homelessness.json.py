"""Observable Framework data loader: Homelessness Dashboard (prototype at
/homelessness/), a deep dive into Local Measure 3.3 "People in Street Outreach,
Emergency Shelter, or Transitional Housing" from the KPI dashboard.

Unlike dashboard.json.py (bridge/dashboard.yml), there is no DAC dashboard
behind this measure to render -- Bridge's own Overview/Demographics widgets
read a pre-aggregated Google Sheet (wcdashboard.performance_metrics) scoped
to "interim housing" (ES/SH/TH/RRH), and Street Outreach isn't a value in
that Sheet at all, so this dashboard can't reuse Bridge's data source. The
sql/homeless_*.sql files are hand-written against wchmiscsv directly instead
(same situation as every sql/ce_*.sql file), matching Bridge's Overview and
Demographics tab *widget shapes* only. See CLAUDE.md's Homeless dashboard
section for the full design rationale.

Two filters -- Project Type (All / Street Outreach / Emergency Shelter /
Transitional Housing) and Household Type (All / Adults Only / Families with
Children / Unaccompanied Minors) -- apply to every query, so every
combination (16 total) is precomputed at build time the same way
dashboard.json.py precomputes its own filter matrix: each SQL file is
rendered with Jinja2 per combination and run once per distinct rendered
query (deduplicated by a hash of the SQL text, not by combo), since a filter
a given query happens to ignore produces the same SQL text twice.

Credentials: standard Google Application Default Credentials. Only the
plain `bigquery` OAuth scope is needed -- no Sheets/Drive involvement here,
unlike dashboard.json.py.
"""

import hashlib
import itertools
import json
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timezone
from decimal import Decimal
from pathlib import Path

import jinja2
from google.cloud import bigquery

BQ_PROJECT_ID = "bruin-508014"
SQL_DIR = Path(__file__).resolve().parents[2] / "sql"

client = bigquery.Client(project=BQ_PROJECT_ID)
env = jinja2.Environment(undefined=jinja2.StrictUndefined)

PROJECT_TYPES = ["All Project Types", "Street Outreach", "Emergency Shelter", "Transitional Housing"]
HOUSEHOLD_TYPES = ["All Household Types", "Adults Only", "Families with Children", "Unaccompanied Minors"]

# Output key -> sql filename, for every precomputed query. All take the
# same two Jinja filters (project_type, household_type) plus the
# @report_start BigQuery scalar parameter.
QUERY_FILES = {
    # Overview tab
    "reach": "homeless_reach.sql",
    "trend": "homeless_trend.sql",
    "living_situation": "homeless_living_situation.sql",
    # Demographics tab
    "priority_households": "homeless_priority_households.sql",
    "race": "homeless_race.sql",
    "ethnicity": "homeless_ethnicity.sql",
    "age": "homeless_age.sql",
}


def json_value(v):
    if isinstance(v, Decimal):
        return float(v)
    if hasattr(v, "isoformat"):
        return v.isoformat()
    return v


def run(sql, report_start):
    job = client.query(sql, job_config=bigquery.QueryJobConfig(
        query_parameters=[bigquery.ScalarQueryParameter("report_start", "DATE", report_start)]
    ))
    result = job.result()
    return {
        "columns": [field.name for field in result.schema],
        "rows": [[json_value(v) for v in row.values()] for row in result],
    }


def fiscal_year(end_year):
    start, end = date(end_year - 1, 10, 1), date(end_year, 9, 30)
    return {"label": f"FY{end_year}", "start": start.isoformat(), "end": end.isoformat()}


def main():
    export_end_job = client.query("SELECT MAX(ExportEndDate) AS d FROM wchmiscsv.Export")
    export_end = next(iter(export_end_job.result()))["d"]
    fy_end_year = export_end.year if export_end >= date(export_end.year, 9, 30) else export_end.year - 1
    current, previous = fiscal_year(fy_end_year), fiscal_year(fy_end_year - 1)
    report_start = date.fromisoformat(current["start"])

    templates = {key: env.from_string((SQL_DIR / filename).read_text()) for key, filename in QUERY_FILES.items()}
    combos = list(itertools.product(PROJECT_TYPES, HOUSEHOLD_TYPES))

    queries, results = {}, {}
    for combo in combos:
        project_type, household_type = combo
        values = {"project_type": project_type, "household_type": household_type}
        key = "|".join(combo)
        results[key] = {}
        for qkey, template in templates.items():
            sql = template.render(filters=values)
            qid = hashlib.sha1(sql.encode()).hexdigest()[:12]
            queries.setdefault(qid, sql)
            results[key][qkey] = qid

    print(f"{len(templates)} queries x {len(combos)} filter combinations = "
          f"{len(templates) * len(combos)} widget results, {len(queries)} distinct queries",
          file=sys.stderr)
    with ThreadPoolExecutor(max_workers=8) as pool:
        data = dict(zip(queries, pool.map(lambda sql: run(sql, report_start), queries.values())))

    json.dump(
        {
            "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "export_end": export_end.isoformat(),
            "fiscal_year": current,
            "previous_fiscal_year": previous,
            "filters": [
                {"name": "project_type", "options": PROJECT_TYPES, "default": PROJECT_TYPES[0]},
                {"name": "household_type", "options": HOUSEHOLD_TYPES, "default": HOUSEHOLD_TYPES[0]},
            ],
            "results": results,
            "data": data,
        },
        sys.stdout,
        separators=(",", ":"),
    )


if __name__ == "__main__":
    main()
