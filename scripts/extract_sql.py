"""Re-extract queries from the westchester-dac repo's System Performance dashboard.

The SQL in sql/ is a copy of every measure widget in wcspm.yml (hmisguru/westchester-dac,
`main` branch) -- both the 6 used by the public KPI tiles (kpis.js/spm.json.py)
and the 3 extra ones (Measures 4, 5.2, 7b.2) used only by the full dashboard
page (src/spm/index.md). All 9 are extracted the same way, so published
numbers on both pages match the dashboard exactly. When a measure's logic
changes there, re-run this against a fresh copy of that file:

    git -C ../westchester-dac show origin/main:wcspm.yml > /tmp/wcspm.yml
    python scripts/extract_sql.py /tmp/wcspm.yml

The dashboard's `{{ filters.report_start }}` date becomes the BigQuery query
parameter `@report_start`, which the data loader sets to the fiscal year being
reported. Its Project filter (by ProjectName) becomes
`(@all_projects OR p.ProjectID IN UNNEST(@project_ids))`. There's no
"funded-projects only" variant here -- that concept doesn't apply to
Westchester, so the loader only ever passes `@all_projects = TRUE`.

One intentional deviation from the dashboard, listed in UNFILTERED_CTES: when
Measure 5.1 is filtered to some projects, the dashboard also narrows its
search for prior homeless-system activity to those same projects, so someone
with a stay elsewhere in the CoC would count as "first-time". The KPIs always
search the whole CoC for prior activity, the same way the dashboard's own
Measure 2 always searches CoC-wide for returns.
"""

import re
import sys
from pathlib import Path

import jinja2
import yaml

SQL_DIR = Path(__file__).resolve().parent.parent / "sql"

# Output file -> exact widget name in wcspm.yml.
WIDGETS = {
    "m1_length_of_time.sql": "Measures 1a and 1b — Average and Median Length of Time Homeless",
    "m2_returns.sql": "Measure 2a/2b — Returns to Homelessness Within 6, 12, and 24 Months",
    "m3_sheltered.sql": "Measure 3.2 — Unduplicated Sheltered Persons",
    "m4_income_growth.sql": "Measures 4.1–4.6 — Employment and Income Growth (CoC-Funded Projects)",
    "m5_first_time.sql": "Measure 5.1 — First-Time Homeless (ES, SH, TH)",
    "m5_2_first_time_ph.sql": "Measure 5.2 — First-Time Homeless (ES, SH, TH, PH)",
    "m7a1_street_outreach.sql": "Measure 7a.1 — Successful Placement from Street Outreach",
    "m7b1_placement.sql": "Measure 7b.1 — Successful Placement (ES, SH, TH, PH-RRH, PH exits without move-in)",
    "m7b2_retention.sql": "Measure 7b.2 — Successful Placement/Retention in Permanent Housing",
}

# CTEs whose Project filter is dropped so they always cover every CoC project.
UNFILTERED_CTES = {
    "m5_first_time.sql": ["scan_projects"],
}

PLACEHOLDER = "__REPORT_START__"
PROJECT_PLACEHOLDER = "__PROJECT_FILTER__"
RENDERED_FILTER = f"AND p.ProjectName IN ('{PROJECT_PLACEHOLDER}')"
PARAM_FILTER = "AND (@all_projects OR p.ProjectID IN UNNEST(@project_ids))"


# The "Exits to permanent housing" KPI counts people who exited Street Outreach
# (Measure 7a.1) OR shelter/SH/TH/RRH (Measure 7b.1) to a permanent destination,
# each person once. It's generated from those two extracted queries: each keeps
# its own logic unchanged through its per-person `classified` CTE, and only the
# final unduplicated count is new.
COMBINED_PH_EXITS = ("m7_exits_to_ph.sql", "m7a1_street_outreach.sql", "m7b1_placement.sql")


def ctes_through_classified(sql, prefix=""):
    """The WITH-list of an extracted measure query, up to its `classified` CTE.

    With a prefix, every CTE name is renamed (bounds -> b_bounds, ...) so two
    queries' CTEs can share one WITH clause.
    """
    body = "\n".join(line for line in sql.splitlines() if not line.lstrip().startswith("--"))
    end = body.index("\nremaining AS (")
    ctes = body[:end].rstrip().rstrip(",")
    if not ctes.startswith("WITH "):
        sys.exit("Unexpected query shape: no leading WITH")
    ctes = ctes[len("WITH "):]
    if prefix:
        for name in sorted(re.findall(r"^(\w+) AS \(", ctes, flags=re.M), key=len, reverse=True):
            ctes = re.sub(rf"\b{name}\b", prefix + name, ctes)
    return ctes


def combined_ph_exits_sql(so_sql, b1_sql):
    return (
        "WITH " + ctes_through_classified(so_sql) + ",\n"
        + ctes_through_classified(b1_sql, prefix="b_") + ",\n"
        + """ph_exits AS (
  SELECT period, PersonalID FROM classified WHERE bucket = 'permanent'
  UNION ALL
  SELECT period, PersonalID FROM b_classified WHERE bucket = 'permanent'
)
SELECT
  COUNT(DISTINCT IF(period = 'Current FY', PersonalID, NULL)) AS current_fy,
  COUNT(DISTINCT IF(period = 'Previous FY', PersonalID, NULL)) AS previous_fy
FROM ph_exits
"""
    )


def drop_cte_filter(sql, cte, filename):
    """Remove the rendered Project filter line from one CTE."""
    start = sql.find(f"{cte} AS (")
    end = sql.find("\n),", start)
    if start < 0 or end < 0 or RENDERED_FILTER not in sql[start:end]:
        sys.exit(f"Could not find the Project filter in CTE {cte} of {filename}")
    body = "\n".join(line for line in sql[start:end].splitlines() if RENDERED_FILTER not in line)
    return sql[:start] + body + sql[end:]


def main(dashboard_path):
    dashboard = yaml.safe_load(Path(dashboard_path).read_text())
    widgets = {
        w["name"]: w
        for row in dashboard["rows"]
        for w in row.get("widgets", [])
    }
    env = jinja2.Environment()
    SQL_DIR.mkdir(exist_ok=True)
    for filename, name in WIDGETS.items():
        if name not in widgets:
            sys.exit(f"Widget not found in {dashboard_path}: {name}")
        sql = env.from_string(widgets[name]["sql"]).render(
            filters={"report_start": PLACEHOLDER, "project": [PROJECT_PLACEHOLDER]}
        )
        sql = sql.replace(f"DATE('{PLACEHOLDER}')", "@report_start")
        if PLACEHOLDER in sql:
            sys.exit(f"Unreplaced report_start placeholder in {name}")
        if RENDERED_FILTER not in sql:
            sys.exit(f"No Project filter found in {name}; the dashboard's filter markup changed")
        for cte in UNFILTERED_CTES.get(filename, []):
            sql = drop_cte_filter(sql, cte, filename)
        sql = sql.replace(RENDERED_FILTER, PARAM_FILTER)
        if PROJECT_PLACEHOLDER in sql:
            sys.exit(f"Unreplaced Project filter placeholder in {name}")
        # Drop blank lines left behind by the Jinja blocks.
        sql = "\n".join(line for line in sql.splitlines() if line.strip()) + "\n"
        header = (
            f"-- Copied from wcspm.yml (hmisguru/westchester-dac, main): \"{name}\".\n"
            "-- Regenerate with scripts/extract_sql.py; do not edit by hand.\n"
        )
        (SQL_DIR / filename).write_text(header + sql)
        print(f"wrote sql/{filename}")

    out, so_file, b1_file = COMBINED_PH_EXITS
    combined = combined_ph_exits_sql((SQL_DIR / so_file).read_text(), (SQL_DIR / b1_file).read_text())
    (SQL_DIR / out).write_text(
        f"-- Generated from sql/{so_file} (Measure 7a.1) and sql/{b1_file} (Measure 7b.1):\n"
        "-- people exiting either to a permanent destination, each counted once.\n"
        "-- Regenerate with scripts/extract_sql.py; do not edit by hand.\n" + combined
    )
    print(f"wrote sql/{out}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: python scripts/extract_sql.py path/to/wcspm.yml")
    main(sys.argv[1])
