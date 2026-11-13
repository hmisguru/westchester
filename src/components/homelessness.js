// Homelessness Dashboard (/homelessness/) -- a deep dive into Local Measure
// 3.3 "People in Street Outreach, Emergency Shelter, or Transitional
// Housing" from the KPI dashboard. Unlike /bridge/, there is no DAC YAML
// behind this page -- see src/data/homelessness.json.py and CLAUDE.md's
// Homelessness Dashboard section for why (Bridge's own Overview/
// Demographics widgets read a pre-aggregated Sheet scoped to "interim
// housing" that has no Street Outreach value at all). Modeled on Bridge's
// Overview tab *widget shapes* only: reach tiles, a trend line chart, a
// stacked bar -- all hand-driven from sql/homeless_*.sql's own result
// shape rather than YAML display config, the same no-YAML convention
// coordinated-entry.js already uses.
//
// Class prefix "hl-" throughout (kept from this page's original /homeless/
// route name -- an internal CSS namespace, not user-facing, so it wasn't
// renamed along with the route).

import * as Plot from "npm:@observablehq/plot";
import {format as d3format} from "npm:d3-format";
import {html, svg} from "npm:htl";
import * as Inputs from "npm:@observablehq/inputs";
import {pie as d3pie, arc as d3arc} from "npm:d3-shape";
import {sankey as d3sankey, sankeyLinkHorizontal as d3sankeyLinkHorizontal} from "npm:d3-sankey";
import {resize} from "observablehq:stdlib";

// Validated categorical palette (dataviz skill reference instance), same
// var(--series-N) convention as dashboard.js/coordinated-entry.js --
// homelessness.css defines the light steps on :root and redefines them under
// html[data-theme="dark"], so toggling the theme recolors every chart with
// no re-render.
const SERIES = [1, 2, 3, 4, 5, 6, 7, 8].map((n) => `var(--series-${n})`);
const integer = d3format(",~f");

const PROJECT_TYPE_ORDER = ["Street Outreach", "Emergency Shelter", "Transitional Housing"];
const LIVING_SITUATION_ORDER = ["Street", "Emergency Shelter / Transitional Housing", "Family or Friends", "Institutional Setting", "Permanent Setting", "Other"];

function empty() {
  return html`<p class="hl-empty">No data for this selection.</p>`;
}

/** Rows for one of the precomputed queries (reach/trend/flow/sankey/...), for the current filter selection. */
export function widgetRows(doc, qkey, filterValues) {
  const qid = doc.results[filterValues.join("|")]?.[qkey];
  if (!qid) return [];
  const {columns, rows} = doc.data[qid];
  return rows.map((r) => Object.fromEntries(columns.map((c, i) => [c, r[i]])));
}

function colorScale(domain) {
  return {domain, range: SERIES.slice(0, Math.max(domain.length, 1)), legend: true};
}

/** A current-vs-previous-FY reach tile (Persons or Households). Neither
 * direction is inherently better here -- more or fewer people active in
 * Street Outreach/ES/TH can reflect more need, more outreach capacity, or
 * real progress, the same ambiguous-direction reasoning coordinated-
 * entry.js's own renderStatTile() already documents for its "People
 * reaching CE" tile -- so this shows a neutral arrow and a plain
 * more/fewer sentence, never an Improved/Worsened label or a color
 * judgment. */
function renderReachTile(field, rows) {
  if (!rows.length) return empty();
  const cur = rows.find((r) => r.period === "Current FY");
  const prev = rows.find((r) => r.period === "Previous FY");
  if (!cur) return empty();
  const body = [html`<div class="hl-metric">${integer(cur[field])}</div>`];
  if (prev) {
    const diff = cur[field] - prev[field];
    const arrow = diff > 0 ? "▲" : diff < 0 ? "▼" : "●";
    const noun = field === "households" ? "households" : "people";
    body.push(html`<p class="hl-metric-note">${arrow} <strong>${integer(Math.abs(diff))}</strong> ${diff >= 0 ? "more" : "fewer"} ${noun} than the previous fiscal year (${integer(prev[field])}).</p>`);
  }
  return body;
}

/** "Persons/Households active by project type over time" -- 12 trailing
 * complete calendar months, one line per project type (Street Outreach/
 * Emergency Shelter/Transitional Housing), colored from the shared SERIES
 * palette in a fixed order so a line's color stays the same across both
 * charts and across filter changes. Per explicit request, this matches
 * "System Flow and Trend Over Time"'s own 12-month window exactly (was
 * previously 8 trailing calendar quarters).
 *
 * sql/homeless_trend.sql's own `period_types` CTE now guarantees a row for
 * every (month, project type) combination the current Project Type filter
 * allows, even when genuinely zero people are active that month -- so,
 * unlike before this change, no JS-side zero-fill is needed here; `rows`
 * comes back already complete and in chronological order. */
function renderTrendChart(rows, field, yLabel) {
  if (!rows.length) return empty();
  const periods = [...new Set(rows.map((r) => r.period))];
  const types = PROJECT_TYPE_ORDER.filter((t) => rows.some((r) => r.project_type === t));
  const fmt = d3format(",~f");
  return resize((width) => Plot.plot({
    width,
    height: 320,
    marginLeft: 56,
    // marginBottom raised from the default to fit -35deg-rotated month
    // labels ("Nov 2026") without clipping against the bottom of the
    // chart's own SVG -- same fix Bridge's own trend charts use.
    marginBottom: 48,
    x: {type: "point", domain: periods, label: null, padding: 0.3, tickRotate: -35},
    y: {grid: true, zero: true, label: yLabel, tickFormat: fmt},
    color: colorScale(types),
    marks: [
      Plot.ruleY([0]),
      Plot.lineY(rows, {x: "period", y: field, stroke: "project_type", strokeWidth: 2}),
      Plot.dot(rows, {x: "period", y: field, fill: "project_type", r: 4, stroke: "var(--theme-background)", strokeWidth: 2}),
      Plot.tip(rows, Plot.pointer({x: "period", y: field, stroke: "project_type", channels: {"Project type": "project_type", [yLabel]: field}, format: {y: false, stroke: false, x: true, "Project type": true, [yLabel]: fmt}}))
    ]
  }));
}

/** "System Flow and Trend Over Time" -- monthly net flow (entries minus
 * exits, i.e. a literal gain/loss of active clients) across 12 trailing
 * complete calendar months, modeled on the private
 * hmisguru/westchester-dac repo's own widget of the same name
 * (wcshelterutilization.yml, Emergency-Shelter-only there), extended per
 * explicit request to this dashboard's own Street Outreach and
 * Transitional Housing too (Westchester has no Safe Haven, so there's
 * nothing to drop there) and to respect this page's own Project Type and
 * Household Type filters, same as every other Overview chart. Bars are a
 * single neutral color rather than colored by sign -- net flow (more
 * people entering than leaving, or the reverse) isn't inherently good or
 * bad, the same ambiguous-direction posture this dashboard's own reach
 * tiles already take (see renderReachTile()'s own header comment), so no
 * green/red value judgment is applied here either. */
function renderFlowChart(rows) {
  if (!rows.length) return empty();
  const fmt = integer;
  const periods = rows.map((r) => r.period);
  const chart = resize((width) => Plot.plot({
    width,
    height: 320,
    marginLeft: 56,
    // tickRotate + marginBottom: same -35deg/48px fix as this file's other
    // long-label "over time" charts (renderTrendChart).
    marginBottom: 48,
    x: {domain: periods, label: null, padding: 0.3, tickRotate: -35},
    y: {grid: true, zero: true, label: "Net flow (entries − exits)", tickFormat: fmt},
    marks: [
      Plot.ruleY([0]),
      Plot.barY(rows, {
        x: "period", y: "net_flow", fill: "var(--series-1)", inset: 1, rx: 2,
        channels: {Entries: "inflow_count", Exits: "outflow_count"},
        tip: {format: {x: true, y: fmt, Entries: fmt, Exits: fmt}}
      }),
      Plot.lineY(rows, {x: "period", y: "trend_value", stroke: "var(--hl-muted)", strokeWidth: 2, strokeDasharray: "5,4"})
    ]
  }));
  return html`<div class="hl-chart-wrap">
    <p class="hl-chart-note">Bars show each month's net flow (entries minus exits); the dashed line is the 12-month trend.</p>
    ${chart}
  </div>`;
}

// "Client Flow: Prior Living Situation -> Project Type -> Exit Outcome" --
// a 3-stage Sankey over the same Active Clients population as every other
// Overview chart, per explicit request. The pinned @observablehq/plot
// version has no Sankey mark (the same "Plot can't draw this layout"
// situation this file's own renderDonut() is already in for pie/arc), so
// node/link geometry comes from the npm:d3-sankey layout generator and is
// emitted as raw SVG via htl's svg tag, same hand-built-SVG technique as
// renderDonut().
//
// sql/homeless_sankey.sql's own header explains the load-bearing design
// choice of leaving the page's own Project Type filter in effect here
// (selecting a single project type collapses the middle stage to one node,
// same as every other Overview chart on this page).
//
// Still-enrolled clients (no Exit record yet) do NOT flow into the Exit
// Outcome stage, per explicit request -- an earlier version gave them a
// 7th "Still Enrolled" node there, but they dominated it (over half of
// total flow in the real data), squeezing the real destination categories
// into thin, hard-to-compare ribbons. renderSankeyChart() instead renders
// each Project Type node's own still-enrolled share as a muted,
// non-flowing cap on that same node -- see that function's own comment.
const SANKEY_LIVING_SITUATION_ORDER = LIVING_SITUATION_ORDER;
const SANKEY_EXIT_ORDER = ["Homeless", "Institutional", "Temporary Housing", "Permanent Housing", "Other", "Unknown"];
// Display-only short forms for node labels, never touching
// sql/homeless_sankey.sql -- same abbreviate-for-the-axis-only convention
// AGE_SHORT_LABELS uses below. Exit Outcome's own names are all short
// enough to show in full already.
const SANKEY_SHORT_LABELS = {
  "Emergency Shelter / Transitional Housing": "ES / TH / SH",
  "Family or Friends": "Family/Friends",
  "Institutional Setting": "Institutional",
  "Permanent Setting": "Permanent"
};

/** Builds the {nodes, links} graph d3-sankey expects from one widget's
 * long-format link rows (stage, source, target, persons), prefixing every
 * node id by its own column -- 'situation'/'project'/'exit' both have an
 * "Other" category, and without the prefix d3-sankey's own nodeId lookup
 * would silently merge those two distinct categories into a single node
 * sitting between all three stages. */
function sankeyGraph(rows) {
  const situationRows = rows.filter((r) => r.stage === "situation");
  const exitRows = rows.filter((r) => r.stage === "exit");
  const nodeId = (column, name) => `${column}:${name}`;
  const livingNames = SANKEY_LIVING_SITUATION_ORDER.filter((n) => situationRows.some((r) => r.source === n));
  const projectNames = PROJECT_TYPE_ORDER.filter((n) => situationRows.some((r) => r.target === n));
  const exitNames = SANKEY_EXIT_ORDER.filter((n) => exitRows.some((r) => r.target === n));
  const nodes = [
    ...livingNames.map((name) => ({id: nodeId("situation", name), name, column: 0, color: SERIES[SANKEY_LIVING_SITUATION_ORDER.indexOf(name) % SERIES.length]})),
    ...projectNames.map((name) => ({id: nodeId("project", name), name, column: 1, color: SERIES[PROJECT_TYPE_ORDER.indexOf(name) % SERIES.length]})),
    ...exitNames.map((name) => ({id: nodeId("exit", name), name, column: 2, color: SERIES[SANKEY_EXIT_ORDER.indexOf(name) % SERIES.length]}))
  ];
  const links = [
    ...situationRows.map((r) => ({source: nodeId("situation", r.source), target: nodeId("project", r.target), value: r.persons})),
    ...exitRows.map((r) => ({source: nodeId("project", r.source), target: nodeId("exit", r.target), value: r.persons}))
  ];
  return {nodes, links};
}

// Below this width, the fixed left/right label margins (110px + 130px)
// leave too little room for the plot itself -- confirmed live at a 380px
// viewport, where node labels from the left and right columns overlapped
// into unreadable mush. Rather than shrinking the margins (which would
// just clip the labels instead), the chart keeps this minimum width and
// sits in a horizontally-scrollable wrapper below it -- same "keep the
// natural size, let the container scroll" fallback the sibling baltimore
// repo's own winter-shelter.js calendar heatmap uses for an identical
// can't-compress-further chart shape.
const SANKEY_MIN_WIDTH = 560;
// Project Type's own column is widened well past d3-sankey's own uniform
// 14px nodeWidth, per explicit request, so each project type's name can
// sit inside its own block instead of floating above it -- the column has
// at most 3 nodes (vs. up to 7 in the other two columns), so it's the one
// column with room to spare. Sized for the longest name ("Transitional
// Housing") at the inside-label font-size below; confirmed live via
// getBoundingClientRect() that the rendered text stays within the box at
// this width, not just eyeballed.
const PROJECT_NODE_WIDTH = 160;

function renderSankeyChart(rows) {
  if (!rows.length) return empty();
  const fmt = integer;
  const marginTop = 28, marginBottom = 10, marginLeft = 110, marginRight = 130, height = 440;
  const chart = resize((containerWidth) => {
    const width = Math.max(containerWidth, SANKEY_MIN_WIDTH);
    const {nodes, links} = sankeyGraph(rows);
    const layout = d3sankey()
      .nodeId((d) => d.id)
      .nodeSort(null)
      .linkSort(null)
      .nodeWidth(14)
      .nodePadding(10)
      .extent([[marginLeft, marginTop], [width - marginRight, height - marginBottom]])
      ({nodes: nodes.map((d) => ({...d})), links: links.map((d) => ({...d}))});
    // Re-center each Project Type node on its own column's existing
    // midpoint, but PROJECT_NODE_WIDTH wide instead of the layout's own
    // 14px -- mutating x0/x1 directly after layout (rather than passing a
    // per-column nodeWidth, which d3-sankey's generator doesn't support)
    // still keeps every link's own path correct, since sankeyLinkHorizontal
    // reads each link's source.x1/target.x0 live off these same node
    // objects when the paths are generated just below.
    for (const n of layout.nodes) {
      if (n.column !== 1) continue;
      const midX = (n.x0 + n.x1) / 2;
      n.x0 = midX - PROJECT_NODE_WIDTH / 2;
      n.x1 = midX + PROJECT_NODE_WIDTH / 2;
    }
    const linkPath = d3sankeyLinkHorizontal();
    const linkEls = layout.links.map((l) => svg`<path d=${linkPath(l)} fill="none" stroke=${l.source.color} stroke-opacity="0.35" stroke-width=${Math.max(1, l.width)}><title>${l.source.name} → ${l.target.name}: ${fmt(l.value)} people</title></path>`);
    const nodeEls = layout.nodes.map((n) => svg`<rect x=${n.x0} y=${n.y0} width=${n.x1 - n.x0} height=${Math.max(1, n.y1 - n.y0)} fill=${n.color} rx="2"><title>${n.name}: ${fmt(n.value)} people</title></rect>`);
    // Still-enrolled clients don't flow anywhere in the third stage (see
    // sql/homeless_sankey.sql's own header) -- rather than appear as a
    // destination node, their share of each Project Type node is capped
    // right there as a muted, non-flowing overlay, and both this split's
    // own numbers (not the node's combined total) are what the node's own
    // label shows (see labelEls below) -- computed once here, shared by
    // both. node.value (the node's own full height) already counts them,
    // by the same inflow-equals-real-exits-plus-still-enrolled
    // conservation sql/homeless_sankey.sql's own exit_links comment
    // documents, so the still-enrolled count is just node.value minus the
    // sum of that node's own outgoing link values -- no separate query or
    // row needed. The cap's own vertical position (not just its height)
    // matters too: d3-sankey stacks a node's outgoing links contiguously
    // from its own y0, so the real exits always occupy the TOP of the
    // node and the uncovered remainder -- found as the lowest edge among
    // those links, or the node's own y0 if it has no real exits at all --
    // is always at the BOTTOM, which is where this cap is drawn.
    const splitByNode = new Map(layout.nodes.filter((n) => n.column === 1).map((n) => {
      const outgoing = layout.links.filter((l) => l.source === n);
      const exited = outgoing.reduce((sum, l) => sum + l.value, 0);
      const flowedBottom = outgoing.length ? Math.max(...outgoing.map((l) => l.y0 + l.width / 2)) : n.y0;
      return [n, {stillEnrolled: n.value - exited, exited, flowedBottom}];
    }));
    const capEls = layout.nodes.filter((n) => n.column === 1).map((n) => {
      const {stillEnrolled, flowedBottom} = splitByNode.get(n);
      if (stillEnrolled <= 0 || flowedBottom >= n.y1) return null;
      return svg`<rect x=${n.x0} y=${flowedBottom} width=${n.x1 - n.x0} height=${Math.max(1, n.y1 - flowedBottom)} fill="black" fill-opacity="0.42" rx="2"><title>${n.name}: ${fmt(stillEnrolled)} still enrolled (hasn't exited yet)</title></rect>`;
    }).filter((el) => el != null);
    // Column 0 labels sit to the right of their node, column 2 to the
    // left, same inside/outside convention most Sankey examples use.
    // Column 1 (Project Type) instead gets its label centered INSIDE its
    // own now-wide block, in white for contrast against the node's own
    // fill color (all 3 Project Type colors are mid-to-dark tones in both
    // themes, confirmed live) -- except when a filter narrows a node's own
    // flow enough that its block is too short to hold a line of text
    // (under 18px tall), where the label falls back to the same
    // centered-above placement every node used before this change, rather
    // than letting the text overflow a tiny box.
    const labelEls = layout.nodes.map((n) => {
      const display = SANKEY_SHORT_LABELS[n.name] ?? n.name;
      // Project Type's own label shows the still-enrolled/exited split
      // (splitByNode, computed above) instead of node.value's own combined
      // total, per explicit request, so the two numbers printed are the
      // same two the node's own visual split (the muted cap vs. the
      // colored portion above it) already shows -- not a third, separate
      // figure a viewer would have to reconcile against what they're
      // looking at.
      if (n.column === 1 && n.y1 - n.y0 >= 40) {
        const {stillEnrolled, exited} = splitByNode.get(n);
        const midX = (n.x0 + n.x1) / 2, midY = (n.y0 + n.y1) / 2;
        return svg`<g>
          <text x=${midX} y=${midY - 10} text-anchor="middle" font-size="11" font-weight="600" fill="#fff">${display}</text>
          <text x=${midX} y=${midY + 4} text-anchor="middle" font-size="10" fill="#fff" fill-opacity="0.9">${fmt(stillEnrolled)} still enrolled</text>
          <text x=${midX} y=${midY + 16} text-anchor="middle" font-size="10" fill="#fff" fill-opacity="0.9">${fmt(exited)} exited</text>
        </g>`;
      }
      if (n.column === 1 && n.y1 - n.y0 >= 18) return svg`<text x=${(n.x0 + n.x1) / 2} y=${(n.y0 + n.y1) / 2} dy="0.32em" text-anchor="middle" font-size="12" font-weight="600" fill="#fff">${display}</text>`;
      if (n.column === 0) return svg`<text x=${n.x1 + 6} y=${(n.y0 + n.y1) / 2} dy="0.32em" font-size="12" fill="currentColor">${display}</text>`;
      if (n.column === 2) return svg`<text x=${n.x0 - 6} y=${(n.y0 + n.y1) / 2} dy="0.32em" text-anchor="end" font-size="12" fill="currentColor">${display}</text>`;
      // Reached only by a column 1 node too short (< 18px) even for its
      // single-line label above -- no room for either number, so just the
      // name (hover the node or its cap for the exact split).
      return svg`<text x=${(n.x0 + n.x1) / 2} y=${n.y0 - 6} text-anchor="middle" font-size="12" fill="currentColor">${display}</text>`;
    });
    return svg`<svg viewBox=${`0 0 ${width} ${height}`} width=${width} height=${height} role="img" aria-label="Prior living situation flowing into project type, flowing into exit outcome">
      ${linkEls}
      ${nodeEls}
      ${capEls}
      ${labelEls}
    </svg>`;
  });
  return html`<div class="hl-chart-wrap"><div class="hl-sankey-scroll">${chart}</div></div>`;
}

// Demographics tab -- Priority Households table, Race/Ethnicity/Age pies
// (sorted horizontal bars, dashboard.js's own renderPie convention: lengths
// compare more accurately than angles) and their own quarter-... er,
// fiscal-year-over-fiscal-year QoQ-shaped tables, all from sql/homeless_race.sql/
// homeless_ethnicity.sql/homeless_age.sql/homeless_priority_households.sql's
// own long-format (period, label, value) rows -- one query per dimension
// serves both its pie (Current FY rows only) and its table (both periods),
// unlike bridge/dashboard.yml's own two-separate-queries-per-dimension shape.
const PRIORITY_HOUSEHOLDS_ORDER = ["Households age 55+", "Disabled households", "Veteran households", "DV Survivor Households"];
const RACE_ORDER = ["AI/AN or Indigenous", "Asian", "Black/African-American", "MENA", "NH/Pacific Islander", "White", "Multiple Races"];
// Fixed per-category color map for the Race donut, rather than the default
// positional SERIES[i] assignment renderDonut() uses elsewhere -- the
// validated palette has two green steps (--series-3, a teal green, and
// --series-6, a pure green), and RACE_ORDER's own list order happened to
// land this CoC's two largest categories, Black/African-American and
// White, on those two greens, confirmed live (both read as shades of the
// same hue in the donut). Black/African-American and White get the
// palette's blue/orange pair instead -- maximally distinct, and the same
// pair ETHNICITY_ORDER's own positional assignment already uses for
// Hispanic/Non-Hispanic, so it's a proven-legible combination on this
// page, not a new untested one. The remaining 5 categories keep
// SERIES' own order (including both greens), which only risks a repeat
// clash if two of those five smaller categories both become among the
// largest two -- much less likely than the original pairing. Still a
// fixed, per-category mapping (never assigned by current rank), so color
// still follows the entity, not its size, across every filter selection.
const RACE_COLORS = {
  "Black/African-American": SERIES[0],
  "White": SERIES[1],
  "AI/AN or Indigenous": SERIES[2],
  "MENA": SERIES[3],
  "NH/Pacific Islander": SERIES[4],
  "Multiple Races": SERIES[5],
  "Asian": SERIES[6]
};
const ETHNICITY_ORDER = ["Hispanic", "Non-Hispanic"];
const AGE_ORDER = ["<1", "1 to 2", "3 to 5", "6 to 17", "17 year-olds who turned 18", "18 to 21", "22 to 24", "25 to 34", "35 to 44", "45 to 54", "55 to 64", "65 and Older"];

/** Race and Ethnicity render as donuts, per explicit request -- same
 * hand-built-with-d3-shape technique the sibling hmisguru/baltimore repo's
 * own bridge.js uses for these same two widgets (the pinned
 * @observablehq/plot version has no arc/pie mark): wedges via d3-shape's
 * pie()/arc() generators, emitted as raw SVG through htl's svg tag. No
 * in-wedge labels (a contrast check against each series color isn't worth
 * it at up to 7 Race slices) -- a center-hole total, a <title>-per-wedge
 * native tooltip, and a legend list (swatch + label + value + percent)
 * carry the same information instead. Filters to Current FY rows first --
 * this dashboard's pies/donuts are always a current-year snapshot, with the
 * QoQ table beside them carrying the previous-year comparison. */
function renderDonut(rows, labelField, valueField, order, colorMap) {
  const current = rows.filter((r) => r.period === "Current FY");
  if (!current.length) return empty();
  const fmt = integer;
  const pct = d3format(".0%");
  const sorted = order
    ? order.filter((o) => current.some((r) => r[labelField] === o)).map((o) => current.find((r) => r[labelField] === o))
    : [...current].sort((a, b) => b[valueField] - a[valueField]);
  const total = sorted.reduce((s, d) => s + (d[valueField] ?? 0), 0);
  // A category's color comes from colorMap when given (a fixed per-entity
  // assignment, e.g. RACE_COLORS), falling back to the default positional
  // SERIES[i] assignment every other chart on this page uses.
  const colors = sorted.map((d, i) => colorMap?.[d[labelField]] ?? SERIES[i % SERIES.length]);

  return resize((width) => {
    const size = Math.min(width, 280);
    const radius = size / 2 - 2;
    const inner = radius * 0.62;
    const arcs = d3pie().value((d) => d[valueField]).sort(null)(sorted);
    const arcGen = d3arc().innerRadius(inner).outerRadius(radius);
    const wedges = arcs.map((a, i) => svg`<path d=${arcGen(a)} fill=${colors[i]} stroke="var(--hl-surface)" stroke-width="2"><title>${sorted[i][labelField]}: ${fmt(sorted[i][valueField])} (${pct(sorted[i][valueField] / total)})</title></path>`);
    const chart = svg`<svg viewBox=${`0 0 ${size} ${size}`} width=${size} height=${size} role="img" aria-label=${`${sorted.map((d) => `${d[labelField]} ${pct(d[valueField] / total)}`).join(", ")}`}>
      <g transform=${`translate(${size / 2},${size / 2})`}>${wedges}</g>
      <text x=${size / 2} y=${size / 2 - 6} text-anchor="middle" font-size="22" font-weight="700" fill="currentColor">${fmt(total)}</text>
      <text x=${size / 2} y=${size / 2 + 14} text-anchor="middle" font-size="12" fill="var(--hl-muted)">total</text>
    </svg>`;
    const legend = html`<ul class="hl-donut-legend">${sorted.map((d, i) => html`<li><span class="hl-donut-swatch" style=${`background:${colors[i]}`}></span>${d[labelField]} — ${fmt(d[valueField])} (${pct(d[valueField] / total)})</li>`)}</ul>`;
    return html`<div class="hl-donut">${chart}${legend}</div>`;
  });
}

// Age (Demographics tab) renders as a stacked histogram, per explicit
// request, same shape as the sibling hmisguru/baltimore repo's own
// bridge.js AGE_HISTOGRAM_WIDGET_NAME/renderAgeHistogram(): x = age
// bracket, y = people served, color = household type stacked within each
// bar. sql/homeless_age.sql's own query already scopes to whichever single
// household type the page's Household type filter has selected, so getting
// all three types on screen at once means pulling this same query's
// precomputed rows for each of the 3 real household-type filter values
// directly out of doc.results (all 16 combinations are already in
// homelessness.json, so this needs no new query) rather than the single rows
// widgetRows() would return for whatever's currently selected -- special-
// cased ahead of the normal render() dispatch in DEMOGRAPHICS_CARDS below,
// the same way that baltimore widget is special-cased ahead of
// renderWidget()'s own dispatch.
const AGE_HOUSEHOLD_TYPES = ["Adults Only", "Families with Children", "Unaccompanied Minors"];
// Display-only short forms for the x axis alone, never touching
// sql/homeless_age.sql -- same population-pyramid-style abbreviations the
// baltimore repo's own AGE_SHORT_LABELS uses for this identical bucket set.
// The hover tip still shows each segment's full original age-bracket name
// via an explicit Age channel.
const AGE_SHORT_LABELS = {
  "<1": "<1", "1 to 2": "1–2", "3 to 5": "3–5", "6 to 17": "6–17",
  "17 year-olds who turned 18": "17→18", "18 to 21": "18–21", "22 to 24": "22–24",
  "25 to 34": "25–34", "35 to 44": "35–44", "45 to 54": "45–54",
  "55 to 64": "55–64", "65 and Older": "65+"
};

function renderAgeHistogram(doc, filterValues) {
  const [projectValue] = filterValues;
  const data = AGE_HOUSEHOLD_TYPES.flatMap((householdType) =>
    widgetRows(doc, "age", [projectValue, householdType])
      .filter((r) => r.period === "Current FY")
      .map((r) => ({...r, household_type: householdType}))
  );
  if (!data.length) return empty();
  const ageOrder = AGE_ORDER.filter((a) => data.some((d) => d.age_bucket === a));
  const fmt = integer;
  const chart = resize((width) => Plot.plot({
    width,
    height: 360,
    marginLeft: 56,
    // tickRotate + marginBottom: same -35deg/48px fix as this file's other
    // long-label charts (renderTrendChart) --
    // AGE_SHORT_LABELS' already-compact forms still don't fit horizontally
    // across 12 categories at a narrow width.
    marginBottom: 48,
    x: {domain: ageOrder, label: "Age", tickFormat: (d) => AGE_SHORT_LABELS[d] ?? d, tickRotate: -35, padding: 0.3},
    y: {grid: true, label: "People served", tickFormat: fmt},
    color: colorScale(AGE_HOUSEHOLD_TYPES),
    marks: [
      Plot.barY(data, Plot.stackY({
        x: "age_bucket",
        y: "persons",
        fill: "household_type",
        order: AGE_HOUSEHOLD_TYPES,
        channels: {Age: "age_bucket", "Household type": "household_type"},
        tip: {format: {x: false, fill: false, Age: true, "Household type": true, y: fmt}}
      })),
      Plot.ruleY([0])
    ]
  }));
  return html`<div>
    <p class="hl-chart-note">The Household type filter does not apply to this chart -- it always breaks out every household type.</p>
    ${chart}
  </div>`;
}

/** A current-vs-previous-FY table over every category of one demographic
 * dimension -- same shape as bridge/dashboard.yml's own QoQ tables
 * (Indicator / Current / Previous / Change), just fiscal-year-over-fiscal-
 * year instead of quarter-over-quarter, computed here from the long-format
 * (period, label, value) rows rather than pivoted in SQL. */
function renderQoqTable(rows, labelField, valueField, order, indicatorHeader = "Indicator") {
  const byLabel = new Map();
  for (const r of rows) {
    const entry = byLabel.get(r[labelField]) ?? {};
    entry[r.period] = r[valueField];
    byLabel.set(r[labelField], entry);
  }
  const labels = order ? order.filter((o) => byLabel.has(o)) : [...byLabel.keys()].sort((a, b) => (byLabel.get(b)["Current FY"] ?? 0) - (byLabel.get(a)["Current FY"] ?? 0));
  if (!labels.length) return empty();
  const fmt = integer;
  const pct = d3format("+.1%");
  return html`<div class="hl-table-wrap"><table class="hl-table">
    <thead><tr><th scope="col">${indicatorHeader}</th><th scope="col" style="text-align:right">Recent FY</th><th scope="col" style="text-align:right">Previous FY</th><th scope="col" style="text-align:right">Change</th></tr></thead>
    <tbody>${labels.map((label) => {
      const cur = byLabel.get(label)["Current FY"];
      const prev = byLabel.get(label)["Previous FY"];
      const change = cur != null && prev ? (cur - prev) / prev : null;
      return html`<tr>
        <td>${label}</td>
        <td style="text-align:right">${cur != null ? fmt(cur) : "—"}</td>
        <td style="text-align:right">${prev != null ? fmt(prev) : "—"}</td>
        <td style="text-align:right">${change != null ? pct(change) : "—"}</td>
      </tr>`;
    })}</tbody>
  </table></div>`;
}

const DEMOGRAPHICS_CARDS = [
  {
    id: "priority-households",
    name: "Priority Households",
    type: "table",
    render: (doc, fv) => renderQoqTable(widgetRows(doc, "priority_households", fv), "indicator", "households", PRIORITY_HOUSEHOLDS_ORDER),
    description: "4 household-level flags, recent fiscal year vs. the previous one: a household counts under Households age 55+ if any member is 55 or older, Disabled households if any member's most recent disability response on file is Yes, Veteran households if any member is a veteran, and DV Survivor Households if any member's most recent domestic violence screening on file says they are a survivor (whether or not they're currently fleeing). A household can count under more than one row, so the 4 figures don't sum to the total households active."
  },
  {
    id: "race-pie",
    name: "Race of People Served — Recent Fiscal Year",
    type: "chart",
    span: 6,
    render: (doc, fv) => renderDonut(widgetRows(doc, "race", fv), "race", "persons", RACE_ORDER, RACE_COLORS),
    description: "Each person's race, from HUD's current (2024+) data standards, which collect race as several yes/no checkboxes rather than one pick. Someone who checked more than one of the 6 race boxes shown here (not counting Hispanic/Latino(a), which this dashboard keeps as its own Ethnicity chart below) is counted once under Multiple Races instead of under each box separately, so this chart's own total can be a little lower than People Active — it excludes anyone who left every race box blank or answered don't know/refused/data not collected."
  },
  {
    id: "ethnicity-pie",
    name: "Ethnicity of People Served — Recent Fiscal Year",
    type: "chart",
    span: 6,
    render: (doc, fv) => renderDonut(widgetRows(doc, "ethnicity", fv), "ethnicity", "persons", ETHNICITY_ORDER),
    description: "Hispanic/Latino(a) vs. not, from the same HUD checkbox Race above excludes so the two charts stay independent of each other. Excludes anyone who left this response blank or answered don't know/refused/data not collected."
  },
  {
    id: "race-qoq",
    name: "Race of People Served",
    type: "table",
    render: (doc, fv) => renderQoqTable(widgetRows(doc, "race", fv), "race", "persons", RACE_ORDER),
    description: "The same Race breakdown as the pie above, recent fiscal year vs. the previous one."
  },
  {
    id: "ethnicity-qoq",
    name: "Ethnicity of People Served",
    type: "table",
    render: (doc, fv) => renderQoqTable(widgetRows(doc, "ethnicity", fv), "ethnicity", "persons", ETHNICITY_ORDER),
    description: "The same Ethnicity breakdown as the pie above, recent fiscal year vs. the previous one."
  },
  {
    id: "age-pie",
    name: "Age of People Served — Recent Fiscal Year",
    type: "chart",
    render: (doc, fv) => renderAgeHistogram(doc, fv),
    description: "Age as of the fiscal year's own start and end dates (not a single point-in-time snapshot), bucketed the same way bridge/dashboard.yml's own Age widget is, including the \"17 year-olds who turned 18\" transition bucket for anyone who had a birthday into adulthood during the year. Shown as a stacked histogram, color = household type, so the age mix within each household type is visible at once -- this is why the chart always shows every household type regardless of the page's own Household type filter."
  },
  {
    id: "age-qoq",
    name: "Age of People Served",
    type: "table",
    render: (doc, fv) => renderQoqTable(widgetRows(doc, "age", fv), "age_bucket", "persons", AGE_ORDER),
    description: "The same Age breakdown as the pie above, recent fiscal year vs. the previous one."
  }
];

const OVERVIEW_CARDS = [
  {
    id: "reach-persons",
    name: "People Active",
    type: "metric",
    render: (doc, fv) => renderReachTile("persons", widgetRows(doc, "reach", fv)),
    description: "Counts every person with an active enrollment in Street Outreach, Emergency Shelter, or Transitional Housing at any point during the fiscal year -- the same \"Active Clients\" definition (entered on or before the period's end, and not exited before the period's start) Local Measure 3.3's own KPI tile uses, just split out by project type and household type here. A person active in more than one of the three project types this year is still counted once in this total."
  },
  {
    id: "reach-households",
    name: "Households Active",
    type: "metric",
    render: (doc, fv) => renderReachTile("households", widgetRows(doc, "reach", fv)),
    description: "The same population as People Active, counted by household instead of by person. Household type is determined from each person's own most-recently-started qualifying enrollment this fiscal year; because of that, this household count can very rarely (a handful out of roughly 2,700 households) be a few higher than the true number of distinct households when a filter narrows to one household type -- the \"All Household Types\" selection isn't affected."
  },
  {
    id: "trend-persons",
    name: "People Active by Project Type, Over Time",
    type: "chart",
    span: 6,
    render: (doc, fv) => renderTrendChart(widgetRows(doc, "trend", fv), "persons", "People"),
    description: "The same Active Clients population as the tiles above, by calendar month for the 12 most recently completed months, broken out by project type -- the same 12-month window the System Flow and Trend Over Time chart below uses. A person active in more than one project type in a given month appears on each of that month's own lines, so the three lines don't sum to a single combined total. A month with genuinely zero people for a filter selection still shows as a point on the zero line rather than a gap, so an empty stretch (e.g. the most recent months, if the current fiscal year's own reach tile above reads zero) reads as \"zero,\" not \"no data.\""
  },
  {
    id: "trend-households",
    name: "Households Active by Project Type, Over Time",
    type: "chart",
    span: 6,
    render: (doc, fv) => renderTrendChart(widgetRows(doc, "trend", fv), "households", "Households"),
    description: "The same monthly population as the chart above, counted by household instead of by person."
  },
  {
    id: "system-flow",
    name: "System Flow and Trend Over Time",
    type: "chart",
    render: (doc, fv) => renderFlowChart(widgetRows(doc, "flow", fv)),
    description: "Each bar shows whether more people entered Street Outreach, Emergency Shelter, or Transitional Housing than left it that month (or the reverse), over the 12 most recently completed calendar months. A person counts as one \"entry\" the month they start a qualifying enrollment and one \"exit\" the month that enrollment ends, so someone active in more than one project type this period is counted once per project type they're active in, the same \"All Project Types\" convention the trend charts above use -- and someone who both enters and exits within the same month nets to zero for that month, which is the correct outcome, not a gap. This is a different count than the reach tiles and trend charts above, which track who's active at a point in time rather than who's coming or going. The dashed line is the overall direction (a best-fit trend), fit over the first 11 of these 12 months and extended through the 12th -- the most recent month's own exits are routinely undercounted by HMIS exit-reporting lag (case managers often log an exit days to weeks after it happens), so leaving it out of the trend's own calculation keeps one likely-incomplete month from swinging the trend's direction; it still shows as its own bar, not hidden, so you can see when the most recent month's own figure runs against the established trend. Modeled on a similar \"System Flow and Trend Over Time\" chart built for this CoC's own Shelter Dashboard, extended here to cover Street Outreach and Transitional Housing in addition to Emergency Shelter."
  },
  {
    id: "flow-sankey",
    name: "Client Flow: Prior Living Situation → Project Type → Exit Outcome",
    type: "chart",
    render: (doc, fv) => renderSankeyChart(widgetRows(doc, "sankey", fv)),
    description: "The same Active Clients population as the rest of this tab, traced through a single path per person: where they were staying right before this enrollment (grouped into 6 categories from HUD's own Prior Living Situation response options), which project type they were active in, and -- for their own representative enrollment -- where they went when they exited. Exit Outcome groups HUD's exit destination codes into Homeless, Institutional, Temporary Housing, and Permanent Housing by HUD's own numeric code bands, plus Other (a recorded but non-housing outcome, such as the person having passed away) and Unknown (don't know/refused/no exit interview/missing). Active clients who haven't exited yet don't flow into the Exit Outcome stage at all -- each Project Type block instead shows them as a darker, non-flowing cap at its own bottom edge (hover it for the exact count), so the real exit destinations' own relative sizes aren't squeezed by a single dominant \"still enrolled\" category. Filtering to a single Project Type collapses the middle stage to one node, same as every other chart on this tab."
  }
];

function renderCard(doc, card, filterValues) {
  const body = card.render(doc, filterValues);
  const isMetric = card.type === "metric";
  // Every card's description collapses behind "About this data" below its
  // own content -- metric tiles included, per explicit request, since
  // People Active/Households Active carry the same real-paragraph
  // methodology text (not a one-line caption) every chart/table card here
  // already collapses. Matches the dashboard-collapsible-description
  // skill's own predicate ("collapse a real paragraph, not a one-liner"),
  // not a type-based exception.
  const description = card.description
    ? html`<details class="hl-card-details"><summary>About this data</summary><p class="hl-card-description">${card.description}</p></details>`
    : null;
  return html`<section class="hl-card${isMetric ? " hl-card-metric" : ""}" style="--span:${card.span ?? (isMetric ? 6 : 12)}" data-widget=${card.id}>
    <h3 class="hl-card-title">${card.name}</h3>
    ${body}
    ${description}
  </section>`;
}

function renderCards(doc, cards, filterValues) {
  return html`<div class="hl-row">${cards.map((card) => renderCard(doc, card, filterValues))}</div>`;
}

/** "Recent Fiscal Year: FY2026" full-width tile at the top of both tabs,
 * the same role bridge/dashboard.yml's own "Current Quarter" tile plays
 * there -- the metric text itself is the date range (not a separate
 * label/value pair), the card title names which fiscal year it is. Doesn't
 * depend on the page's filters, so it's rendered once per tab ahead of
 * that tab's own filtered cards rather than living in OVERVIEW_CARDS/
 * DEMOGRAPHICS_CARDS (whose render(doc, fv) signature implies a filtered
 * result). No description -- a date range needs no "About this data".
 * "Recent" rather than "Current", per explicit request, everywhere this
 * period is named on the page -- the FY in question is the most recently
 * COMPLETE fiscal year as of the HMIS export (see homeless_reach.sql's own
 * header comment), not the fiscal year underway right now, so "Recent"
 * reads more accurately than "Current". The underlying data/period key
 * stays "Current FY" throughout the SQL/loader/JS (an internal identifier,
 * not shown to a visitor) -- only user-facing text changed. */
function renderFiscalYearCard(doc) {
  const fy = doc.fiscal_year;
  const range = `${calendarDate(fy.start)} – ${calendarDate(fy.end)}`;
  return html`<div class="hl-row">
    <section class="hl-card hl-card-metric" style="--span:12" data-widget="fiscal-year">
      <h3 class="hl-card-title">Recent Fiscal Year: ${fy.label}</h3>
      <div class="hl-metric">${range}</div>
    </section>
  </div>`;
}

/** All Overview cards, laid out on the 12-column grid. */
export function renderOverview(doc, filterValues) {
  return html`${renderFiscalYearCard(doc)}${renderCards(doc, OVERVIEW_CARDS, filterValues)}`;
}

/** All Demographics cards, laid out on the 12-column grid. */
export function renderDemographics(doc, filterValues) {
  return html`${renderFiscalYearCard(doc)}${renderCards(doc, DEMOGRAPHICS_CARDS, filterValues)}`;
}

// Loose matching for option names given in a URL: case, spaces and
// punctuation are ignored. Not used yet (no embed page), kept for parity
// with dashboard.js's own match() in case one is added later.
const slug = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
const match = (options, value) => (value == null ? undefined : options.find((o) => slug(o) === slug(value)));

const TAB_NAMES = ["Overview", "Demographics"];

/** The two filter selects (Project type, Household type) plus the Overview/
 * Demographics tab strip, starting from the document's own defaults unless
 * `initial` names valid option values. */
export function homelessInputs(doc, initial = {}) {
  const [projectFilter, householdFilter] = doc.filters;
  const project = Inputs.select(projectFilter.options, {label: "Project type", value: match(projectFilter.options, initial.project_type) ?? projectFilter.default});
  const household = Inputs.select(householdFilter.options, {label: "Household type", value: match(householdFilter.options, initial.household_type) ?? householdFilter.default});
  const tabs = Inputs.radio(TAB_NAMES, {value: match(TAB_NAMES, initial.tab) ?? TAB_NAMES[0]});
  tabs.classList.add("hl-tabs");
  return {project, household, tabs, controls: html`<div class="hl-controls">${project}${household}</div>`};
}

const eastern = (iso, options) => new Date(iso).toLocaleString("en-US", {timeZone: "America/New_York", ...options});
// fy.start/fy.end are bare calendar dates ("2025-10-01"), not real instants
// -- formatting them through America/New_York like a timestamp would shift
// them a day earlier (midnight Eastern is already the previous day in UTC),
// the same class of bug this repo's own winter-shelter.js header comment
// documents for DAC's date x-axis. Parsed and formatted as UTC instead, so
// the calendar date shown always matches the date string exactly.
const calendarDate = (isoDate) => new Date(isoDate + "T00:00:00Z").toLocaleString("en-US", {timeZone: "UTC", dateStyle: "medium"});

/** "Recent FY: FY2026 (Oct 1, 2025 - Sep 30, 2026) · Dashboard refreshed ...", in Eastern time. */
export function renderFootnote(doc) {
  const fy = doc.fiscal_year;
  const range = `${calendarDate(fy.start)} – ${calendarDate(fy.end)}`;
  return html`<p class="hl-footnote">Recent fiscal year: ${fy.label} (${range}) · Dashboard refreshed ${eastern(doc.generated, {dateStyle: "medium", timeStyle: "short"})}.</p>`;
}

/** A short intro panel above the filters, matching the plain-box shape
 * every other dashboard's own "About this dashboard" note uses (bridge-
 * about, hl-about share the same CSS shape, just under this page's own
 * prefix). Hand-written here rather than pulled from any YAML -- there is
 * none behind this page. */
export function renderAbout() {
  return html`<section class="hl-about" aria-label="About this dashboard">
    <p>A deep dive into Local Measure 3.3, "People in Street Outreach, Emergency Shelter, or Transitional Housing," from the KPI dashboard. Use the filters below to break the measure down by project type and household type.</p>
  </section>`;
}

const THEME_KEY = "homeless-theme";

function storedTheme() {
  try {
    return localStorage.getItem(THEME_KEY);
  } catch {
    return null;
  }
}

function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  try {
    localStorage.setItem(THEME_KEY, theme);
  } catch {
    // Private browsing / blocked storage: theme still applies for this page view.
  }
}

/** A light/dark theme toggle button, default light -- see homelessness.css for
 * the [data-theme] styling this drives on <html>. Remembers the visitor's
 * choice via localStorage (own key, not shared with any other dashboard on
 * this site), but every first-ever visit starts light. */
export function renderThemeToggle() {
  const theme = storedTheme() === "dark" ? "dark" : "light";
  applyTheme(theme);

  const label = (t) => (t === "dark" ? "☀️ Light mode" : "🌙 Dark mode");
  const button = html`<button type="button" class="hl-theme-toggle">${label(theme)}</button>`;
  button.setAttribute("aria-pressed", String(theme === "dark"));
  button.addEventListener("click", () => {
    const next = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
    applyTheme(next);
    button.setAttribute("aria-pressed", String(next === "dark"));
    button.textContent = label(next);
  });
  return button;
}
