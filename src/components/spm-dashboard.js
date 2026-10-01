// Renders the full System Performance Dashboard (src/data/spm-dashboard.json)
// as a static page: one renderer per DAC `type: table` widget, driven by
// each widget's own columns config, so the layout matches wcspm.yml
// (hmisguru/westchester) -- same widget order and intro notes as
// balspm.yml (hmisguru/baltimore, `staging` branch), which this was built
// from directly, per explicit request.
//
// CoC-wide only, per explicit choice -- a per-project dropdown version of
// this file (and its matching data loader) is archived at
// archive/spm-dashboard.js / archive/spm-dashboard.json.py for possible
// later reactivation; see archive/README.md.

import {format as d3format} from "npm:d3-format";
import {html} from "npm:htl";

function numberFormat(spec) {
  if (!spec || spec === "number") return d3format(",~f");
  try {
    return d3format(spec);
  } catch {
    return String;
  }
}

function empty() {
  return html`<p class="spmd-empty">No data for this measure.</p>`;
}

/** One `type: table` widget: a plain HTML table, columns driven by its own config. */
function renderWidgetTable(widget) {
  if (!widget.rows.length) return empty();
  const cols = widget.columns;
  const cell = (c, v) => {
    const fmt = c.number ? numberFormat(c.number) : null;
    return v == null ? "—" : fmt && typeof v === "number" ? fmt(v) : v;
  };
  return html`<div class="spmd-table-wrap"><table class="spmd-table">
    <thead><tr>${cols.map((c) => html`<th scope="col">${c.label ?? c.name}</th>`)}</tr></thead>
    <tbody>${widget.rows.map((r) => html`<tr>${cols.map((c) => html`<td>${cell(c, r[c.name])}</td>`)}</tr>`)}</tbody>
  </table></div>`;
}

function renderWidget(widget) {
  return html`<section class="spmd-card">
    <h3 class="spmd-card-title">${widget.name}</h3>
    <p class="spmd-card-description">${widget.description}</p>
    ${renderWidgetTable(widget)}
  </section>`;
}

/** The dashboard's intro note (adapted from balspm.yml's "Dashboard Notes" widget). */
export function renderNotes(data) {
  return html`<div class="spmd-notes">
    HUD System Performance Measures, for the Westchester County Continuum of Care (NY-604), across
    every CoC project. "Current FY" is the most recent complete federal fiscal year (Oct 1 – Sep 30,
    ${data.fiscal_year.start} to ${data.fiscal_year.end}) covered by the HMIS export dated
    ${data.export_end}; "Previous FY" is the 12 months immediately prior
    (${data.previous_fiscal_year.start} to ${data.previous_fiscal_year.end}). This page has no Fiscal
    Year Start Date or Project filter -- it's a static snapshot of the current reporting year for
    every CoC project, refreshed monthly (first Wednesday of each month) when this site rebuilds.
    Only projects participating in the CoC (Project.ContinuumProject = 1) are included;
    enrollments are scoped to CoC NY-604 (the only CoC code present in this dataset). Measure 3.1 (PIT
    counts) is intentionally omitted -- HUD specifies it is manually entered from separate
    Point-in-Time count submissions, not generated from HMIS data. Measure 6 (Category 3 /
    High-Performing Community) is intentionally omitted -- HUD has not designated any CoCs as
    high-performing communities, so no projects are required to report it.
  </div>`;
}

/** Every measure widget, in wcspm.yml/balspm.yml's own order, CoC-wide. */
export function renderDashboard(data) {
  return html`<div>${data.widgets.map(renderWidget)}</div>`;
}
