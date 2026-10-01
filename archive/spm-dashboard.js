// Renders the full System Performance Dashboard (src/data/spm-dashboard.json)
// as a static page: one renderer per DAC `type: table` widget, driven by
// each widget's own columns config, so the layout matches wcspm.yml
// (hmisguru/westchester-dac) -- same widget order and intro notes as
// balspm.yml (hmisguru/baltimore-dac, `staging` branch), which this was built
// from directly, per explicit request.

import {format as d3format} from "npm:d3-format";
import {html} from "npm:htl";

const ALL_PROJECTS_ID = "";

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

/**
 * Narrow the spm-dashboard.json document to one project. By default (or
 * projectId="" / undefined) every CoC project; otherwise the single named
 * project from data.projects, computed independently at build time (NOT a
 * sum of per-project pieces -- the loader runs each project as its own
 * full query, since several widgets' per-person dedup logic can't be
 * validly recombined from precomputed pieces). Narrowing only changes each
 * measure's *initial* client universe -- any CoC-wide scan a measure does
 * downstream (prior homelessness history, searching for a return) is
 * unaffected, same as the live DAC dashboard's own Project filter (see
 * spm-dashboard.json.py's module docstring).
 */
export function scopeData(data, projectId) {
  if (!projectId) return data;
  const project = data.projects.find((p) => String(p.id) === String(projectId));
  if (!project) throw new Error(`Unknown project id ${projectId}`);
  return {...data, widgets: project.widgets, scope_label: project.name};
}

/** The dashboard's intro note (adapted from balspm.yml's "Dashboard Notes" widget). */
export function renderNotes(data) {
  return html`<div class="spmd-notes">
    HUD System Performance Measures, for the Westchester County Continuum of Care (NY-604).
    "Current FY" is the most recent complete federal fiscal year (Oct 1 – Sep 30,
    ${data.fiscal_year.start} to ${data.fiscal_year.end}) covered by the HMIS export dated
    ${data.export_end}; "Previous FY" is the 12 months immediately prior
    (${data.previous_fiscal_year.start} to ${data.previous_fiscal_year.end}). This page has
    no Fiscal Year Start Date control -- it's a static snapshot of the current reporting
    year, refreshed when this site rebuilds. The Project dropdown below narrows which
    project counts toward each measure's starting universe only; any further CoC-wide
    search a measure does (prior homelessness history, a later return to homelessness)
    still covers every CoC project. It lists open projects (no end date) of a type HUD's
    SPM programming specs cover. Only projects participating in the CoC (Project.ContinuumProject = 1) are
    included; enrollments are scoped to CoC NY-604 (the only CoC code present in this
    dataset). Measure 3.1 (PIT counts) is intentionally omitted -- HUD specifies it is
    manually entered from separate Point-in-Time count submissions, not generated from HMIS
    data. Measure 6 (Category 3 / High-Performing Community) is intentionally omitted --
    HUD has not designated any CoCs as high-performing communities, so no projects are
    required to report it.
  </div>`;
}

function footerText(data) {
  return [data.scope_label ?? "All CoC projects", data.source].filter(Boolean).join(" · ");
}

/**
 * Every measure widget, in wcspm.yml/balspm.yml's own order, with a Project
 * dropdown above them that swaps between precomputed scopes client-side
 * (no live queries) -- "All CoC projects" plus one option per project in
 * data.projects (already sorted by name by the loader).
 *
 * @param {string} [options.projectId=""]  which project to start on ("" = all CoC projects)
 */
export function renderDashboard(data, {projectId = ALL_PROJECTS_ID} = {}) {
  const wrapper = html`<div class="spmd-wrapper">`;
  const grid = html`<div>`;
  const footerNode = html`<p class="spmd-scope-footer">`;
  footerNode.setAttribute("aria-live", "polite");

  const render = (id) => {
    const scoped = scopeData(data, id);
    grid.replaceChildren(...scoped.widgets.map(renderWidget));
    footerNode.textContent = footerText(scoped);
  };

  const selectId = `spmd-project-${Math.random().toString(36).slice(2)}`;
  const select = html`<select class="spmd-select" id=${selectId}>
    <option value=${ALL_PROJECTS_ID}>All CoC projects</option>
    ${data.projects.map((p) => html`<option value=${p.id}>${p.name}</option>`)}
  </select>`;
  select.value = projectId;
  select.addEventListener("change", () => render(select.value));
  wrapper.append(html`<div class="spmd-controls">
    <label class="spmd-select-label" for=${selectId}>Project</label>
    ${select}
  </div>`);

  render(projectId);
  wrapper.append(grid, footerNode);
  return wrapper;
}
