"""Observable Framework data loader: Westchester Performance Dashboard
(prototype at /bridge/).

Renders the DAC dashboard definition in bridge/dashboard.yml statically: runs
each widget's own SQL at build time for every combination of the dashboard's
two filters (household type x project type), and writes the widget layout
plus all results as one JSON document. The page then switches filters
instantly in the browser, with no queries at view time.

Queries are deduplicated by their rendered SQL, so a widget that ignores a
filter (e.g. the System Flow/Length of Time/Positive Outcomes tabs, where
Project Type doesn't apply) runs once per distinct query rather than once per
combination.

The dashboard reads wcdashboard.performance_metrics, a view over a Google
Sheets external table, so credentials need the Drive scope as well as
BigQuery, and the service account must have read access to the Sheet. The
Sheet's Drive modified time is included as "source_modified" for the page
footer -- any failure there only drops that one line, it never fails the
build.
"""

import hashlib
import itertools
import json
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

import google.auth
from google.auth.transport.requests import AuthorizedSession
import jinja2
import yaml
from google.cloud import bigquery

BQ_PROJECT_ID = "bruin-508014"
# The Google Sheets external table behind wcdashboard.performance_metrics.
SOURCE_TABLE = f"{BQ_PROJECT_ID}.wcdashboard.sheet"
DASHBOARD = Path(__file__).resolve().parents[2] / "bridge" / "dashboard.yml"
SCOPES = [
    "https://www.googleapis.com/auth/bigquery",
    "https://www.googleapis.com/auth/drive.readonly",
]

credentials, _ = google.auth.default(scopes=SCOPES)
client = bigquery.Client(project=BQ_PROJECT_ID, credentials=credentials)

# Widget keys passed through to the page as display config (never SQL).
DISPLAY_KEYS = ["chart", "x", "y", "color", "stacked", "value", "label", "columns", "slices", "content"]

# Widgets hidden from this page, matched by their DAC `name` rather than
# position so a refresh of dashboard.yml doesn't silently un-hide them.
# Skipped entirely, not just hidden visually -- no layout entry and no SQL
# template is built for it, so no query runs and no empty widget card
# appears either. Mirrors the sibling dashboard's own HIDDEN_WIDGET_NAMES
# convention, per explicit request to match its System Engagement tab
# exactly: "Household system-engagement mix over time" is hidden there too
# (it exists in that dashboard's own source YAML but was never shown on the
# live page -- confirmed by reading its loader, not just its widget list);
# "Quarter-over-quarter comparison" has no equivalent in that dashboard's
# source at all.
HIDDEN_WIDGET_NAMES = {
    "Household system-engagement mix over time",
    "Quarter-over-quarter comparison",
}

# "DV Survivor Households" -- NOT part of dashboard.yml (never hand-edited;
# see this module's own docstring), since the Priority households widget's
# own dashboard.yml SQL only reads category = 'Summary' and has no concept
# of this measure at all. Added here directly instead, as an extra row
# merged onto that same widget's own per-combo table result (see the end of
# main()), the same one-off-query-outside-the-YAML convention used for
# other dashboards on this site. Copies that widget's own filter CASE
# pattern and QoQ (date-ranked, current vs. previous) logic verbatim, just
# scoped to the 'Domestic Violence Survivor Status' category: a household
# counts if its `set` is anything other than "No history of domestic
# violence reported".
PRIORITY_HOUSEHOLDS_WIDGET_NAME = "Priority households — quarter-over-quarter"
DV_SURVIVOR_INDICATOR = "DV Survivor Households"
PRIORITY_HOUSEHOLDS_ORDER = ["Households age 55+", "Disabled households", "Veteran households", DV_SURVIVOR_INDICATOR]
DV_SURVIVOR_SQL = """
WITH scoped AS (
  SELECT
    date,
    '""" + DV_SURVIVOR_INDICATOR + """' AS indicator,
    SUM(value) AS value
  FROM `wcdashboard.performance_metrics`
  WHERE date >= DATE_DIFF(DATE '2024-01-01', DATE '1899-12-30', DAY)
    AND category = 'Domestic Violence Survivor Status'
    AND `set` != 'No history of domestic violence reported'
    AND (CASE '{{ filters.household_type }}' WHEN 'Adults Only' THEN 'AO' WHEN 'Families with Children' THEN 'AC' WHEN 'Unaccompanied Minors' THEN 'CO' ELSE 'ALL' END = 'ALL' OR population_group = CASE '{{ filters.household_type }}' WHEN 'Adults Only' THEN 'AO' WHEN 'Families with Children' THEN 'AC' WHEN 'Unaccompanied Minors' THEN 'CO' ELSE 'ALL' END)
    AND (CASE '{{ filters.project_type }}' WHEN 'ES/SH/TH' THEN 'ES,SH,TH' WHEN 'RRH' THEN 'RRH' ELSE 'ALL' END = 'ALL' OR project_type = CASE '{{ filters.project_type }}' WHEN 'ES/SH/TH' THEN 'ES,SH,TH' WHEN 'RRH' THEN 'RRH' ELSE 'ALL' END)
    AND project_type != 'PSH'
  GROUP BY 1, 2
), ranked AS (
  SELECT date, DENSE_RANK() OVER (ORDER BY date DESC) AS period_rank
  FROM (SELECT DISTINCT date FROM scoped)
)
SELECT
  indicator,
  MAX(IF(period_rank = 1, value, NULL)) AS current_value,
  MAX(IF(period_rank = 2, value, NULL)) AS previous_value,
  SAFE_DIVIDE(MAX(IF(period_rank = 1, value, NULL)) - MAX(IF(period_rank = 2, value, NULL)), MAX(IF(period_rank = 2, value, NULL))) AS qoq_change
FROM scoped
JOIN ranked USING (date)
WHERE period_rank <= 2
GROUP BY indicator
"""


def json_value(v):
    if isinstance(v, Decimal):
        return float(v)
    if hasattr(v, "isoformat"):
        return v.isoformat()
    return v


def run(sql):
    job = client.query(sql)
    result = job.result()
    return {
        "columns": [field.name for field in result.schema],
        "rows": [[json_value(v) for v in row.values()] for row in result],
    }


def source_modified():
    """When the source Sheet was last modified (ISO timestamp), or None.

    Only feeds the footer, so any failure is a warning, not a failed build.
    """
    try:
        uri = client.get_table(SOURCE_TABLE).external_data_configuration.source_uris[0]
        sheet_id = uri.split("/spreadsheets/d/")[1].split("/")[0]
        response = AuthorizedSession(credentials).get(
            f"https://www.googleapis.com/drive/v3/files/{sheet_id}",
            params={"fields": "modifiedTime", "supportsAllDrives": "true"},
            timeout=30,
        )
        response.raise_for_status()
        return response.json()["modifiedTime"]
    except Exception as e:  # noqa: BLE001
        print(f"warning: couldn't read the source Sheet's modified time: {e}", file=sys.stderr)
        return None


def main():
    dashboard = yaml.safe_load(DASHBOARD.read_text())
    filters = [
        {"name": f["name"], "options": f["options"]["values"], "default": f["default"]}
        for f in dashboard["filters"]
    ]
    combos = list(itertools.product(*[f["options"] for f in filters]))
    env = jinja2.Environment(undefined=jinja2.StrictUndefined)

    # Layout: rows are grouped by tab name, in order of each tab's first
    # appearance. Widget ids (r<row>-w<widget>) match dashboard.yml's own row
    # order, so results can be compared one-to-one against that source file.
    tabs, notes, sql_templates = {}, [], {}
    for ri, row in enumerate(dashboard["rows"]):
        widgets = []
        for wi, w in enumerate(row.get("widgets", [])):
            if w.get("name") in HIDDEN_WIDGET_NAMES:
                continue
            wid = f"r{ri}-w{wi}"
            widgets.append({
                "id": wid,
                "type": w["type"],
                "name": w.get("name"),
                "description": (w.get("description") or "").strip() or None,
                "col": w.get("col", 12),
                **{k: w[k] for k in DISPLAY_KEYS if k in w},
            })
            if w.get("sql"):
                sql_templates[wid] = env.from_string(w["sql"])
        if not widgets:
            continue
        if "tab" not in row:
            notes.extend(widgets)
        else:
            tabs.setdefault(row["tab"], {"name": row["tab"], "rows": []})["rows"].append(widgets)
    tabs = list(tabs.values())

    # Render every widget's SQL for every filter combination; run each
    # distinct query once.
    priority_wid = next(
        (w["id"] for tab in tabs for row in tab["rows"] for w in row if w["name"] == PRIORITY_HOUSEHOLDS_WIDGET_NAME),
        None,
    )
    dv_template = env.from_string(DV_SURVIVOR_SQL)
    queries, results, dv_qids = {}, {}, {}
    for combo in combos:
        values = {f["name"]: v for f, v in zip(filters, combo)}
        key = "|".join(combo)
        results[key] = {}
        for wid, template in sql_templates.items():
            sql = template.render(filters=values)
            qid = hashlib.sha1(sql.encode()).hexdigest()[:12]
            queries.setdefault(qid, sql)
            results[key][wid] = qid
        if priority_wid:
            dv_sql = dv_template.render(filters=values)
            dv_qid = hashlib.sha1(dv_sql.encode()).hexdigest()[:12]
            queries.setdefault(dv_qid, dv_sql)
            dv_qids[key] = dv_qid

    print(f"{len(sql_templates)} widgets x {len(combos)} filter combinations = "
          f"{len(sql_templates) * len(combos)} widget results, {len(queries)} distinct queries",
          file=sys.stderr)
    with ThreadPoolExecutor(max_workers=8) as pool:
        data = dict(zip(queries, pool.map(run, queries.values())))

    # Merge the DV Survivor Households row onto Priority households' own
    # per-combo table result (see DV_SURVIVOR_SQL above for why this isn't
    # just another dashboard.yml widget). augmented_qids guards against
    # appending twice when two combos render identical SQL and share a qid.
    augmented_qids = set()
    for key, qid in dv_qids.items():
        ph_qid = results[key].get(priority_wid)
        if not ph_qid or ph_qid in augmented_qids:
            continue
        augmented_qids.add(ph_qid)
        dv_rows = data[qid]["rows"]
        dv_row = dv_rows[0] if dv_rows else [DV_SURVIVOR_INDICATOR, None, None, None]
        data[ph_qid]["rows"].append(dv_row)
        data[ph_qid]["rows"].sort(key=lambda r: PRIORITY_HOUSEHOLDS_ORDER.index(r[0]))

    json.dump(
        {
            "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "source_modified": source_modified(),
            "name": dashboard["name"],
            "description": dashboard.get("description"),
            "filters": filters,
            "notes": notes,
            "tabs": tabs,
            "results": results,
            "data": data,
        },
        sys.stdout,
        separators=(",", ":"),
    )


if __name__ == "__main__":
    main()
