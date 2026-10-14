// Renders the Westchester Performance Dashboard (bridge/dashboard.yml, a
// verbatim copy of hmisguru/westchester-dac's own dashboard.yml) from the
// build-time results in src/data/dashboard.json: one renderer per DAC widget
// type, driven by each widget's own display config (fields, formats,
// widths), so the YAML stays the single definition of what each widget
// shows. Class prefix "bridge-" throughout, matching this page's own /bridge/
// route -- not a reference to any other site.

import * as Plot from "npm:@observablehq/plot";
import {format as d3format} from "npm:d3-format";
import {marked} from "npm:marked";
import {html, svg} from "npm:htl";
import * as Inputs from "npm:@observablehq/inputs";
import {hierarchy, treemap as d3treemap} from "npm:d3-hierarchy";
import {pie as d3pie, arc as d3arc} from "npm:d3-shape";
import {resize} from "observablehq:stdlib";

// Validated categorical palette (dataviz skill reference instance), assigned
// in this fixed order, never cycled. Each slot is a CSS custom property
// rather than a raw hex so Plot's SVG output (which resolves var() in
// presentation attributes, same as any other CSS color) picks up the
// dark-mode step automatically -- dashboard.css defines --series-1..8 for
// light mode and redefines them under html[data-theme="dark"], so toggling
// the theme recolors every chart with no re-render needed.
const SERIES = [1, 2, 3, 4, 5, 6, 7, 8].map((n) => `var(--series-${n})`);

/** The widget's result for the chosen filters, as an array of row objects. */
export function widgetRows(dashboard, widget, filterValues) {
  const qid = dashboard.results[filterValues.join("|")]?.[widget.id];
  if (!qid) return [];
  const {columns, rows} = dashboard.data[qid];
  return rows.map((r) => Object.fromEntries(columns.map((c, i) => [c, r[i]])));
}

// Finds a widget by name across every tab, not just the one currently
// rendering -- used when a tile needs another tab's widget data, e.g. the
// System Flow glossary's "Returned" tile pulling its trend pill from
// "Returns After Permanent Placement vs. 4-Quarter Average", which lives
// under Positive Outcomes.
function findWidget(dashboard, name) {
  for (const tab of dashboard.tabs) {
    for (const row of tab.rows) {
      const w = row.find((x) => x.name === name);
      if (w) return w;
    }
  }
  return null;
}

function numberFormat(spec) {
  if (!spec || spec === "number") return d3format(",~f");
  try {
    return d3format(spec);
  } catch {
    return String;
  }
}

// Category order as it comes from SQL (the dashboard's own queries already sort).
const uniq = (rows, field) => [...new Set(rows.map((d) => d[field]))];

function empty() {
  return html`<p class="bridge-empty">No data for this selection.</p>`;
}

function renderMetric(widget, rows) {
  if (!rows.length) return empty();
  const {field, format, type} = widget.value ?? {};
  const raw = rows[0][field];
  const text = type === "number" && raw != null ? numberFormat(format)(raw) : raw ?? "—";
  const signed = type === "number" && format?.includes("%") && raw > 0 ? `+${text}` : text;
  return html`<div class="bridge-metric${type === "number" ? "" : " bridge-metric-text"}">${signed}</div>`;
}

function renderText(widget) {
  const div = html`<div class="bridge-text">`;
  div.innerHTML = marked.parse(widget.content ?? "");
  return div;
}

function colorScale(domain) {
  return {domain, range: SERIES.slice(0, Math.max(domain.length, 1)), legend: true};
}

function renderLine(widget, rows) {
  const x = widget.x.field, y = widget.y.field, color = widget.color?.field;
  const fmt = numberFormat(widget.y.format);
  return resize((width) => Plot.plot({
    width,
    height: 320,
    marginLeft: 56,
    // marginBottom raised from the default to fit -35deg-rotated quarter
    // labels ("2024 Q1") without clipping against the bottom of the chart's
    // own SVG.
    marginBottom: 48,
    x: {type: "point", domain: uniq(rows, x), label: widget.x.title ?? null, padding: 0.3, tickRotate: -35},
    y: {grid: true, zero: true, label: widget.y.title ?? null, tickFormat: fmt},
    color: color ? colorScale(uniq(rows, color)) : undefined,
    marks: [
      Plot.ruleY([0]),
      Plot.lineY(rows, {x, y, stroke: color ?? SERIES[0], strokeWidth: 2}),
      Plot.dot(rows, {x, y, fill: color ?? SERIES[0], r: 4, stroke: "var(--theme-background)", strokeWidth: 2}),
      Plot.tip(rows, Plot.pointer({x, y, stroke: color, channels: {[widget.y.title ?? y]: y}, format: {y: false, stroke: true, x: true, [widget.y.title ?? y]: fmt}}))
    ]
  }));
}

// "Average days in the system over time" shows 3 increasingly inclusive
// definitions of length of stay (ES/SH Only -> + TH -> + days searching for
// permanent housing) as separate colored lines in dashboard.yml itself.
// Shown one at a time behind a "Pathway" dropdown instead, so it reads as 3
// nested definitions of the same measure rather than 3 separate client
// populations -- the widget's own rows already carry all 3 pathways (color:
// measure in the YAML), so this needs no new query, just a client-side
// filter re-drawn into a container div on each dropdown change.
const LENGTH_OF_TIME_WIDGET_NAME = "Average days in the system over time";
const PATHWAY_ORDER = ["ES/SH Only", "ES/SH + TH", "ES/SH/TH + Days In Permanent Housing Search"];
const PATHWAY_DEFAULT = "ES/SH Only";

function renderLengthOfTimeChart(widget, rows) {
  if (!rows.length) return empty();
  const x = widget.x.field, y = widget.y.field, color = widget.color.field;
  const fmt = numberFormat(widget.y.format);
  const pathways = PATHWAY_ORDER.filter((p) => rows.some((r) => r[color] === p));
  const select = Inputs.select(pathways, {label: "Pathway", value: pathways.includes(PATHWAY_DEFAULT) ? PATHWAY_DEFAULT : pathways[0]});
  const chartSlot = html`<div>`;
  const draw = (pathway) => {
    const filtered = rows.filter((r) => r[color] === pathway);
    chartSlot.replaceChildren(resize((width) => Plot.plot({
      width,
      height: 320,
      marginLeft: 56,
      marginBottom: 48,
      x: {type: "point", domain: uniq(filtered, x), label: widget.x.title ?? null, padding: 0.3, tickRotate: -35},
      y: {grid: true, zero: true, label: widget.y.title ?? null, tickFormat: fmt},
      marks: [
        Plot.ruleY([0]),
        Plot.lineY(filtered, {x, y, stroke: SERIES[0], strokeWidth: 2}),
        Plot.dot(filtered, {x, y, fill: SERIES[0], r: 4, stroke: "var(--theme-background)", strokeWidth: 2}),
        Plot.tip(filtered, Plot.pointer({x, y, channels: {[widget.y.title ?? y]: y}, format: {y: false, x: true, [widget.y.title ?? y]: fmt}}))
      ]
    })));
  };
  select.addEventListener("input", () => draw(select.value));
  draw(select.value);
  return html`<div>
    <p class="bridge-chart-note">Each pathway counts a different, increasingly inclusive mix of interim housing types toward a client's length of stay: <strong>ES/SH Only</strong> counts nights in Emergency Shelter and Safe Haven; <strong>ES/SH + TH</strong> adds Transitional Housing; <strong>ES/SH/TH + Days In Permanent Housing Search</strong> also adds time spent searching for and moving into permanent housing.</p>
    <div class="bridge-controls">${select}</div>
    ${chartSlot}
  </div>`;
}

function renderBar(widget, rows) {
  const x = widget.x.field, y = widget.y.field, color = widget.color?.field;
  const fmt = numberFormat(widget.y.format);
  return resize((width) => Plot.plot({
    width,
    height: 340,
    marginLeft: 56,
    x: {domain: uniq(rows, x), label: widget.x.title ?? null, padding: 0.3},
    y: {grid: true, label: widget.y.title ?? null, tickFormat: fmt},
    color: color ? colorScale(uniq(rows, color)) : undefined,
    marks: [
      Plot.barY(rows, Plot.stackY({x, y, fill: color ?? SERIES[0], order: uniq(rows, color), inset: 1, rx: 2, tip: {format: {y: fmt}}})),
      Plot.ruleY([0])
    ]
  }));
}

// Pie charts become sorted horizontal bars with value and share labels:
// lengths along one axis compare more accurately than angles.
function renderPie(widget, rows) {
  const label = widget.label, value = widget.value.field;
  const fmt = numberFormat(widget.value.format);
  const total = rows.reduce((s, d) => s + (d[value] ?? 0), 0);
  const pct = d3format(".0%");
  const sorted = [...rows].sort((a, b) => b[value] - a[value]);
  return resize((width) => Plot.plot({
    width,
    height: 40 + sorted.length * 36,
    marginLeft: Math.min(220, width * 0.4),
    marginRight: 110,
    x: {axis: null},
    y: {domain: sorted.map((d) => d[label]), label: null, tickSize: 0},
    marks: [
      Plot.barX(sorted, {y: label, x: value, fill: SERIES[0], rx: 2, insetTop: 6, insetBottom: 6}),
      Plot.text(sorted, {y: label, x: value, text: (d) => `${fmt(d[value])} (${pct(d[value] / total)})`, textAnchor: "start", dx: 6, fill: "currentColor"})
    ]
  }));
}

// Race and Ethnicity (Demographics tab) render as donuts instead -- every
// other `chart: pie` widget on this dashboard stays renderPie's sorted-
// horizontal-bars (lengths compare more accurately than angles), so this is
// a deliberate override of two named widgets. The pinned @observablehq/plot
// version has no arc/pie mark, so the wedges are hand-built with d3-shape's
// pie()/arc() generators and emitted as raw SVG via htl's svg tag. No
// in-wedge labels -- a center hole total, a <title>-per-wedge native
// tooltip, and a legend list (swatch + label + value + percent) carry the
// same information instead.
const DONUT_WIDGET_NAMES = new Set(["Race of People Served — Current Quarter", "Ethnicity of People Served — Current Quarter"]);

function renderDonut(widget, rows) {
  if (!rows.length) return empty();
  const label = widget.label, value = widget.value.field;
  const fmt = numberFormat(widget.value.format);
  const total = rows.reduce((s, d) => s + (d[value] ?? 0), 0);
  const pct = d3format(".0%");
  const sorted = [...rows].sort((a, b) => b[value] - a[value]);
  const colors = SERIES.slice(0, sorted.length);

  return resize((width) => {
    const size = Math.min(width, 280);
    const radius = size / 2 - 2;
    const inner = radius * 0.62;
    const arcs = d3pie().value((d) => d[value]).sort(null)(sorted);
    const arcGen = d3arc().innerRadius(inner).outerRadius(radius);
    const wedges = arcs.map((a, i) => svg`<path d=${arcGen(a)} fill=${colors[i]} stroke="var(--bridge-surface)" stroke-width="2"><title>${sorted[i][label]}: ${fmt(sorted[i][value])} (${pct(sorted[i][value] / total)})</title></path>`);
    const chart = svg`<svg viewBox=${`0 0 ${size} ${size}`} width=${size} height=${size} role="img" aria-label=${`${widget.name}: ${sorted.map((d) => `${d[label]} ${pct(d[value] / total)}`).join(", ")}`}>
      <g transform=${`translate(${size / 2},${size / 2})`}>${wedges}</g>
      <text x=${size / 2} y=${size / 2 - 6} text-anchor="middle" font-size="22" font-weight="700" fill="currentColor">${fmt(total)}</text>
      <text x=${size / 2} y=${size / 2 + 14} text-anchor="middle" font-size="12" fill="var(--bridge-muted)">total</text>
    </svg>`;
    const legend = html`<ul class="bridge-donut-legend">${sorted.map((d, i) => html`<li><span class="bridge-donut-swatch" style=${`background:${colors[i]}`}></span>${d[label]} — ${fmt(d[value])} (${pct(d[value] / total)})</li>`)}</ul>`;
    return html`<div class="bridge-donut">${chart}${legend}</div>`;
  });
}

// Age (Demographics tab) renders as a stacked histogram instead of a pie --
// x = age bracket, y = people served, color = household type stacked within
// each bar. This widget's own SQL already scopes to whichever single
// household type the page's Household type filter has selected, so getting
// all three types on screen at once means pulling this same widget's
// precomputed rows for each of the 3 household-type filter values directly
// out of dashboard.results (all 16 filter combinations are already in
// dashboard.json, so this needs no new query), not the single rows the
// normal widgetRows() call in renderWidget would return for whatever's
// currently selected -- special-cased ahead of renderWidget's normal rows/
// dispatch logic entirely, since gating on !rows.length for only the
// currently-selected combo would wrongly blank the chart whenever that one
// combo happens to be zero.
const AGE_HISTOGRAM_WIDGET_NAME = "Age of People Served — Current Quarter";
const AGE_HOUSEHOLD_TYPES = ["Adults Only", "Families with Children", "Unaccompanied Minors"];
// The dashboard's own age bracket names ("17 year-olds who turned 18") are
// far too long to fit as 12 side-by-side x-axis labels even rotated --
// display-only population-pyramid-style short forms for the x axis alone,
// never touching dashboard.yml; the hover tip still shows each segment's
// full original age-bracket name via an explicit Age channel.
const AGE_ORDER = ["<1", "1 to 2", "3 to 5", "6 to 17", "17 year-olds who turned 18", "18 to 21", "22 to 24", "25 to 34", "35 to 44", "45 to 54", "55 to 64", "65 and Older"];
const AGE_SHORT_LABELS = {
  "<1": "<1", "1 to 2": "1–2", "3 to 5": "3–5", "6 to 17": "6–17",
  "17 year-olds who turned 18": "17→18", "18 to 21": "18–21", "22 to 24": "22–24",
  "25 to 34": "25–34", "35 to 44": "35–44", "45 to 54": "45–54",
  "55 to 64": "55–64", "65 and Older": "65+"
};

function renderAgeHistogram(dashboard, widget, filterValues) {
  const label = widget.label, value = widget.value.field;
  const fmt = numberFormat(widget.value.format);
  const projectValue = filterValues[1];
  const data = AGE_HOUSEHOLD_TYPES.flatMap((householdType) =>
    widgetRows(dashboard, widget, [householdType, projectValue]).map((r) => ({...r, household_type: householdType}))
  );
  if (!data.length) return empty();
  const ageOrder = AGE_ORDER.filter((a) => data.some((d) => d[label] === a));
  const chart = resize((width) => Plot.plot({
    width,
    height: 340,
    marginLeft: 56,
    marginBottom: 48,
    x: {domain: ageOrder, label: "Age", tickFormat: (d) => AGE_SHORT_LABELS[d] ?? d, tickRotate: -35, padding: 0.3},
    y: {grid: true, label: "People served", tickFormat: numberFormat(",.0f")},
    color: colorScale(AGE_HOUSEHOLD_TYPES),
    marks: [
      Plot.barY(data, Plot.stackY({
        x: label,
        y: value,
        fill: "household_type",
        order: AGE_HOUSEHOLD_TYPES,
        channels: {Age: label, "Household type": "household_type"},
        tip: {format: {x: false, fill: false, Age: true, "Household type": true, y: fmt}}
      })),
      Plot.ruleY([0])
    ]
  }));
  return html`<div>
    <p class="bridge-chart-note">The <strong>Household type</strong> filter does not apply to this chart -- it always breaks out every household type.</p>
    ${chart}
  </div>`;
}

// System engagement treemap: d3-hierarchy computes the rectangle layout
// (Plot has no hierarchical-layout mark of its own), Plot.rect draws it so
// it stays visually/interactively consistent with the rest of this file
// (color scale + legend, Plot.tip, resize()). Two-level hierarchy:
// widget.label split on " — " gives the group (household type) and part
// (engagement state); group nodes get a padded header strip for their own
// label, leaves are colored from the widget's own `slices` map in the YAML
// (keyed by the full "Group — Part" label, e.g. "Adults Only — Returned").
function renderTreemap(widget, rows) {
  if (!rows.length) return empty();
  const value = widget.value.field;
  const fmt = numberFormat(widget.value.format);
  const data = rows.map((d) => {
    const [group, part] = String(d[widget.label]).split(/\s+—\s+/);
    return {...d, _group: group, _part: part ?? group};
  });
  const groups = uniq(data, "_group");
  const segments = uniq(data, widget.label);
  const slices = widget.slices ?? {};
  const color = {
    domain: segments,
    range: segments.map((s, i) => slices[s]?.color ?? SERIES[i % SERIES.length])
  };
  const HEADER = 22;

  const root = hierarchy({children: groups.map((g) => ({name: g, children: data.filter((d) => d._group === g)}))})
    .sum((d) => d[value] ?? 0)
    .sort((a, b) => b.value - a.value);

  return resize((width) => {
    const height = 70 + groups.length * 130;
    d3treemap().size([width, height]).paddingOuter(4).paddingTop(HEADER).paddingInner(2)(root);
    const leaves = root.leaves();
    const big = leaves.filter((d) => d.x1 - d.x0 > 64 && d.y1 - d.y0 > 30);
    return Plot.plot({
      width,
      height,
      marginLeft: 0,
      marginRight: 0,
      marginTop: 0,
      marginBottom: 0,
      x: {domain: [0, width], axis: null},
      y: {domain: [height, 0], axis: null},
      color,
      marks: [
        // Group header bands + labels (household type)
        Plot.rect(root.children, {x1: "x0", x2: "x1", y1: "y0", y2: (d) => Math.min(d.y0 + HEADER, d.y1), fill: "currentColor", fillOpacity: 0.06}),
        Plot.text(root.children, {x: "x0", y: "y0", dx: 6, dy: 14, text: (d) => d.data.name, textAnchor: "start", fontWeight: 700, fontSize: 12, fill: "currentColor"}),
        // Leaves (engagement state within each household type), colored by segment
        Plot.rect(leaves, {
          x1: "x0", x2: "x1", y1: "y0", y2: "y1",
          fill: (d) => d.data[widget.label],
          stroke: "var(--theme-background)",
          strokeWidth: 1.5,
          inset: 0.5,
          rx: 2,
          channels: {
            "Household type": (d) => d.data._group,
            "Engagement state": (d) => d.data._part,
            Households: (d) => d.data[value]
          },
          tip: {
            format: {x: false, y: false, fill: false, "Household type": true, "Engagement state": true, Households: fmt}
          }
        }),
        Plot.text(big, {x: (d) => (d.x0 + d.x1) / 2, y: (d) => (d.y0 + d.y1) / 2, dy: -6, text: (d) => d.data._part, fill: "white", fontWeight: 600, fontSize: 11}),
        Plot.text(big, {x: (d) => (d.x0 + d.x1) / 2, y: (d) => (d.y0 + d.y1) / 2, dy: 10, text: (d) => fmt(d.data[value]), fill: "white", fontSize: 11})
      ]
    });
  });
}

// DAC conditional formats: [{if: "greater_than_or_equal", value, ...style}, {...fallback}]
const COMPARE = {
  greater_than_or_equal: (a, b) => a >= b,
  greater_than: (a, b) => a > b,
  less_than_or_equal: (a, b) => a <= b,
  less_than: (a, b) => a < b,
  equal: (a, b) => a === b
};
// Fixed in both themes -- white text on a solid fill reads fine regardless
// of page background, so these never need a dark variant. "neutral" is a
// plain mid-gray for trendPill()'s "about the same" case below.
const STATUS_COLORS = {green: "#0a6e0a", red: "#b3261e", neutral: "#52525b"};

function styleFor(rules, v) {
  for (const rule of rules ?? []) {
    if (!rule.if || COMPARE[rule.if]?.(v, rule.value)) return rule;
  }
  return null;
}

// No "Indicator" column header on any of this dashboard's quarter-over-
// quarter detail tables (Priority households, Race/Ethnicity, System
// indicators, the two "vs. 4-Quarter Average" context tables) -- every one
// of these tables is a plain name-plus-figures shape, so the header adds
// nothing the row values don't already say. Gated on the column's own name
// ("indicator") rather than a per-widget list, so it applies to every table
// built on that same column shape, including any added later -- the Length
// of Time quarter-over-quarter table is unaffected since its first column
// is named "measure", not "indicator" (dashboard.yml's own column
// definition).
function renderTable(widget, rows) {
  if (!rows.length) return empty();
  const cols = (widget.columns ?? Object.keys(rows[0]).map((name) => ({name}))).filter((c) => !c.hidden);
  const headerText = (c) => (c.name === "indicator" ? "" : c.label ?? c.name);
  const cell = (c, v) => {
    const fmt = c.number ? numberFormat(c.number) : null;
    const text = v == null ? "—" : fmt && typeof v === "number" ? fmt(v) : v;
    const rule = styleFor(c.format, v);
    if (!rule) return text;
    const bg = STATUS_COLORS[rule.backgroundColor] ?? rule.backgroundColor;
    return html`<span class="bridge-pill" style="background:${bg};color:${rule.textColor ?? "inherit"};font-weight:${rule.bold ? 700 : 400}">${text}</span>`;
  };
  const align = (c) => `text-align:${c.align ?? "left"}`;
  return html`<div class="bridge-table-wrap"><table class="bridge-table">
    <thead><tr>${cols.map((c) => html`<th scope="col" style=${align(c)}>${headerText(c)}</th>`)}</tr></thead>
    <tbody>${rows.map((r) => html`<tr>${cols.map((c) => html`<td style=${align(c)}>${cell(c, r[c.name])}</td>`)}</tr>`)}</tbody>
  </table></div>`;
}

// One short phrase built from a "... vs. 4-Quarter Average" widget's own
// one-row table (current_value/pct_of_average/comparison_label/
// rolling_avg_4q), e.g. "▲ 5.0% above the 200 average". Within
// +/-2% of average, the pill drops the number entirely for a plain "about
// the same as" rather than asking the reader to parse a decimal percent as
// negligible themselves, in a neutral ink pill. Beyond that threshold, the
// arrow and color still encode direction and whether that's good or bad for
// this measure -- color pulled from the widget's own pct_of_average column
// `format` rule via styleFor(), so a widget where *below* average is green
// (Established/New/Recurring/Returned) colors correctly without a
// widget-specific special case here. Shared by renderTrendTile() below and
// the System Flow glossary tiles.
const NEGLIGIBLE_CHANGE = 0.02;
function trendPill(trendWidget, trendRows) {
  if (!trendRows?.length) return null;
  const {pct_of_average, rolling_avg_4q} = trendRows[0];
  if (pct_of_average == null) return null;
  const avg = numberFormat("number")(rolling_avg_4q);
  const change = pct_of_average - 1;
  if (Math.abs(change) < NEGLIGIBLE_CHANGE) {
    return html`<p class="bridge-exits-pill" style="background:${STATUS_COLORS.neutral}">≈ About the ${avg} average</p>`;
  }
  const above = change > 0;
  const pct = d3format(".1%")(Math.abs(change));
  const pctColumn = trendWidget?.columns?.find((c) => c.name === "pct_of_average");
  const rule = styleFor(pctColumn?.format, pct_of_average);
  const bg = STATUS_COLORS[rule?.backgroundColor] ?? rule?.backgroundColor ?? STATUS_COLORS[above ? "green" : "red"];
  return html`<p class="bridge-exits-pill" style="background:${bg}">${above ? "▲" : "▼"} ${pct} ${above ? "above" : "below"} the ${avg} average</p>`;
}

// Restyles a "... vs. 4-Quarter Average" single-row table widget into a
// plain-language tile (big number + trendPill()'s sentence below it)
// instead of a 4-column table -- the underlying widget already carries
// everything needed (current_value plus the trend columns), so this is
// display-only, no new data.
function renderTrendTile(widget, rows) {
  if (!rows.length) return empty();
  const value = numberFormat("number")(rows[0].current_value);
  return html`<div class="bridge-metric">${value}</div>${trendPill(widget, rows)}`;
}
const TREND_TILE_WIDGET_NAMES = new Set(["Households Exiting to Permanent Housing vs. 4-Quarter Average"]);

// Glossary of the 4 engagement states shown on the System Flow tab's
// treemap and quarter-over-quarter table -- not a DAC widget, so it's a
// hand-built component (like renderAbout) rather than something driven by
// dashboard.yml. Labels match the chart's own labels (the SQL's own
// CASE ... AS engagement_state in that YAML) exactly. Each state's
// trendWidget points at a one-row "... — Trend" (or "... vs. 4-Quarter
// Average") table that exists solely to feed that tile's pill -- see
// PILL_ONLY_WIDGET_NAMES below, which keeps the 3 new ones off their own
// visible card, and also hides "Returns After Permanent Placement vs.
// 4-Quarter Average" from Positive Outcomes, since the Returned tile here
// already shows that same figure. Per explicit instruction elsewhere on
// this dashboard, *below* average is the positive direction for all 4
// states -- fewer households stuck, newly homeless, recurring, or returning
// is the improvement -- the opposite polarity from Positive Outcomes' own
// exits tile, where *above* average (more exits to permanent housing) is
// good; that polarity is already baked into each widget's own
// pct_of_average column format rule in dashboard.yml, so trendPill() colors
// each state correctly with no extra logic here.
const ENGAGEMENT_STATES = [
  {
    label: "Established",
    accent: "#2a78d6", bg: "#ebf2f9", border: "#b6cfed",
    accentDark: "#3987e5", bgDark: "#312d58", borderDark: "#33457d",
    definition: "Continuously homeless since a prior report period — doesn't fit the other three states.",
    trendWidget: "Established — Trend"
  },
  {
    label: "New",
    accent: "#eb6834", bg: "#f9efeb", border: "#edc5b6",
    accentDark: "#d95926", bgDark: "#4a2639", borderDark: "#703334",
    definition: "First-time entry into the system this reporting period.",
    trendWidget: "New — Trend"
  },
  {
    label: "Recurring",
    accent: "#1baf7a", bg: "#ebf9f4", border: "#b6edd9",
    accentDark: "#199e70", bgDark: "#2b3145", borderDark: "#274d50",
    definition: "Re-engaged with the system after a previous temporary or unknown-destination exit.",
    trendWidget: "Recurring — Trend"
  },
  {
    label: "Returned",
    accent: "#eda100", bg: "#f9f5eb", border: "#eddbb6",
    accentDark: "#c98500", bgDark: "#482d33", borderDark: "#694326",
    definition: "Returned to homelessness this reporting period after a previous permanent housing placement.",
    trendWidget: "Returns After Permanent Placement vs. 4-Quarter Average"
  }
];

// households-per-state totals, keyed by ENGAGEMENT_STATES label, from the
// treemap widget's own rows -- so a tile's stat matches whatever the chart
// below it is currently showing, household-type filter included.
function engagementTotals(rows) {
  const fmt = numberFormat(",.0f");
  const totals = new Map();
  for (const r of rows) totals.set(r.engagement_state, (totals.get(r.engagement_state) ?? 0) + (r.households ?? 0));
  return (label) => (totals.has(label) ? fmt(totals.get(label)) : null);
}

function renderEngagementLegend(dashboard, rows, filterValues) {
  const totalFor = engagementTotals(rows);
  return html`<div class="bridge-legend" aria-label="Engagement state definitions">${ENGAGEMENT_STATES.map((s) => {
    const trendWidget = s.trendWidget ? findWidget(dashboard, s.trendWidget) : null;
    const pill = trendWidget ? trendPill(trendWidget, widgetRows(dashboard, trendWidget, filterValues)) : null;
    const total = totalFor(s.label);
    const heading = total != null
      ? html`<p class="bridge-legend-stat">${total} <span>${s.label} Households</span></p>`
      : html`<p class="bridge-legend-title"><span class="bridge-legend-dot"></span>${s.label}</p>`;
    return html`
    <div class="bridge-legend-tile" style="--tile-bg:${s.bg};--tile-border:${s.border};--tile-accent:${s.accent};--tile-bg-dark:${s.bgDark};--tile-border-dark:${s.borderDark};--tile-accent-dark:${s.accentDark}">
      ${heading}
      ${pill}
      <p>${s.definition}</p>
    </div>
  `;
  })}</div>`;
}

// Established/New/Recurring — Trend exist solely to feed the System Flow
// glossary tiles' pills (via findWidget() + trendPill() in
// renderEngagementLegend) and should never also show up as their own
// visible card. "Returns After Permanent Placement vs. 4-Quarter Average"
// is also hidden here -- the Returned glossary tile above already shows
// that same figure, so showing it again on Positive Outcomes would be
// redundant (same reasoning as dropping the other 3).
const PILL_ONLY_WIDGET_NAMES = new Set([
  "Established — Trend",
  "New — Trend",
  "Recurring — Trend",
  "Returns After Permanent Placement vs. 4-Quarter Average"
]);

function dropPillOnlyWidgets(rows) {
  return rows.map((row) => row.filter((w) => !PILL_ONLY_WIDGET_NAMES.has(w.name))).filter((row) => row.length);
}

// dashboard.yml puts "Current Quarter" in its own full-width row at the top
// of every tab, with a different row right after depending on the tab:
// three tabs (System Flow, Length of Time, Positive Outcomes) follow it
// with the "Project Type Filter Note" text widget; the other two (Overview,
// Demographics) follow it with the two total-served tiles. Both cases are
// merged into Current Quarter's row here, with each widget's width set via
// a `col` override on a shallow copy. Current Quarter itself is a fixed
// 4/12 on every tab (so it reads the same width wherever it appears); the
// note takes the complementary 8/12 beside it, and the two served-count
// tiles split the other 8/12 evenly with it (4/4/4).
const CURRENT_QUARTER_SPAN = 4;
function mergeQuarterTopRow(rows) {
  const withCol = (w, col) => ({...w, col});
  const merged = [];
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    const next = rows[i + 1];
    const nextNames = next?.map((w) => w.name) ?? [];
    if (row.length !== 1 || row[0].name !== "Current Quarter") {
      merged.push(row);
      continue;
    }
    if (next?.length === 1 && nextNames[0] === "Project Type Filter Note") {
      merged.push([withCol(row[0], CURRENT_QUARTER_SPAN), withCol(next[0], 12 - CURRENT_QUARTER_SPAN)]);
      i++;
    } else if (next?.length === 2 && nextNames.includes("People Served in Interim Housing") && nextNames.includes("Households Served in Interim Housing")) {
      merged.push([row[0], ...next].map((w) => withCol(w, CURRENT_QUARTER_SPAN)));
      i++;
    } else {
      merged.push([withCol(row[0], CURRENT_QUARTER_SPAN)]);
    }
  }
  return merged;
}

// Display-only renames, none of which touch dashboard.yml itself -- the
// same TITLE_OVERRIDES convention used elsewhere on this site for a DAC
// source's own label that reads better (or matches a sibling dashboard's
// own wording) once rendered. Westchester's own dashboard.yml and the
// sibling site's own source YAML were authored independently by each CoC's
// own consultant, so a handful of tab/widget names differ in wording for
// functionally identical content; these are the ones worth aligning.
// "People Served/Households Served in Interim Housing" needed no override
// here -- dashboard.yml itself was renamed to match (and its own SQL now
// excludes PSH, per explicit request, so the name is accurate, not just
// copied).
const TAB_TITLE_OVERRIDES = {"System Flow": "System Engagement"};
const WIDGET_TITLE_OVERRIDES = {
  "Priority households — quarter-over-quarter": "Priority Households",
  "Permanent-destination exits — quarter-over-quarter detail": "Exits to Permanent Destinations by Household Type",
  // The tile itself (big number + trend pill) already states the
  // comparison, so the card heading doesn't need to repeat "vs. 4-Quarter
  // Average" -- matches the sibling dashboard's own shorter card title for
  // its functionally equivalent (there, two-widget) tile.
  "Households Exiting to Permanent Housing vs. 4-Quarter Average": "Households Exiting to Permanent Housing"
};
const displayTabName = (name) => TAB_TITLE_OVERRIDES[name] ?? name;
const displayWidgetName = (name) => WIDGET_TITLE_OVERRIDES[name] ?? name;

function renderWidget(dashboard, widget, filterValues) {
  let body;
  // Special-cased ahead of the normal rows/dispatch logic below, not added
  // as another widget.chart === "pie" branch -- this widget ignores the
  // currently selected household-type filter entirely (it shows all three
  // at once instead).
  if (widget.name === AGE_HISTOGRAM_WIDGET_NAME) {
    body = renderAgeHistogram(dashboard, widget, filterValues);
  } else {
    const rows = widgetRows(dashboard, widget, filterValues);
    if (TREND_TILE_WIDGET_NAMES.has(widget.name)) body = renderTrendTile(widget, rows);
    else if (widget.type === "text") body = renderText(widget);
    else if (widget.type === "metric") body = renderMetric(widget, rows);
    else if (widget.type === "table") body = renderTable(widget, rows);
    else if (!rows.length) body = empty();
    else if (widget.chart === "line") body = widget.name === LENGTH_OF_TIME_WIDGET_NAME ? renderLengthOfTimeChart(widget, rows) : renderLine(widget, rows);
    else if (widget.chart === "bar") body = renderBar(widget, rows);
    else if (widget.chart === "pie") body = DONUT_WIDGET_NAMES.has(widget.name) ? renderDonut(widget, rows) : renderPie(widget, rows);
    else if (widget.chart === "treemap") body = renderTreemap(widget, rows);
    else body = html`<p class="bridge-empty">Unsupported widget type: ${widget.chart ?? widget.type}</p>`;
  }

  const isNote = widget.type === "text";
  const isMetricLike = widget.type === "metric" || TREND_TILE_WIDGET_NAMES.has(widget.name);
  const span = widget.col ?? 12;
  return html`<section class="bridge-card${isNote ? " bridge-note" : ""}${isMetricLike ? " bridge-card-metric" : ""}" style="--span:${span}" data-widget=${widget.id}>
    ${isNote ? null : html`<h3 class="bridge-card-title">${displayWidgetName(widget.name)}</h3>`}
    ${body}
  </section>`;
}

/** All rows of one tab, laid out on the dashboard's 12-column grid. */
export function renderTab(dashboard, tabName, filterValues) {
  const tab = dashboard.tabs.find((t) => t.name === tabName) ?? dashboard.tabs[0];
  const rows = mergeQuarterTopRow(dropPillOnlyWidgets(tab.rows));
  return html`<div class="bridge-tab">${rows.map((row) => {
    const treemapWidget = row.find((w) => w.name === "System engagement by household type");
    return html`
    ${treemapWidget ? renderEngagementLegend(dashboard, widgetRows(dashboard, treemapWidget, filterValues), filterValues) : null}
    <div class="bridge-row">${row.map((w) => renderWidget(dashboard, w, filterValues))}</div>
  `;
  })}</div>`;
}

// The dashboard's one untabbed note ("Dashboard Notes"), shown above the
// filters: its opening text spans the panel, and its "### " sections
// (Household Type / Project Type filter definitions) sit side by side below
// it, matching this widget's own front-loaded structure in dashboard.yml.
export function renderAbout(dashboard) {
  return html`<section class="bridge-about" aria-label="About this dashboard">${dashboard.notes.map((w) => {
    const [intro, ...sections] = (w.content ?? "").split(/^### /m);
    const block = (md, cls) => {
      const div = html`<div class=${cls}>`;
      div.innerHTML = marked.parse(md);
      return div;
    };
    return html`<div class="bridge-about-note">
      ${intro.trim() ? block(intro, "bridge-text bridge-about-intro") : null}
      ${sections.length ? html`<div class="bridge-about-terms">${sections.map((sec) => block(`### ${sec}`, "bridge-text bridge-about-term"))}</div>` : null}
    </div>`;
  })}</section>`;
}

// Loose matching for option names given in a URL: case, spaces and
// punctuation are ignored.
const slug = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
const match = (options, value) => (value == null ? undefined : options.find((o) => slug(o) === slug(value)));

/**
 * The filter selects and the tab strip, starting from the dashboard's
 * defaults unless `initial` names a valid {tab, household, project}. Filter
 * values stay in the dashboard's own order (household, project) for result
 * lookups.
 */
export function dashboardInputs(dashboard, initial = {}) {
  const [householdFilter, projectFilter] = dashboard.filters;
  const tabNames = dashboard.tabs.map((t) => t.name);
  const household = Inputs.select(householdFilter.options, {label: "Household type", value: match(householdFilter.options, initial.household) ?? householdFilter.default});
  const project = Inputs.select(projectFilter.options, {label: "Project type", value: match(projectFilter.options, initial.project) ?? projectFilter.default});
  const tabs = Inputs.radio(tabNames, {value: match(tabNames, initial.tab) ?? tabNames[0], format: displayTabName});
  tabs.classList.add("bridge-tabs");
  return {household, project, tabs, controls: html`<div class="bridge-controls">${household}${project}</div>`};
}

const eastern = (iso, options) => new Date(iso).toLocaleString("en-US", {timeZone: "America/New_York", ...options});

/** "Source data last updated … · Dashboard refreshed …", in Eastern time. */
export function renderFootnote(dashboard) {
  const source = dashboard.source_modified ? `Source data last updated ${eastern(dashboard.source_modified, {dateStyle: "medium"})} · ` : "";
  return html`<p class="bridge-footnote">${source}Dashboard refreshed ${eastern(dashboard.generated, {dateStyle: "medium", timeStyle: "short"})}.</p>`;
}

const THEME_KEY = "bridge-theme";

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

/** A light/dark theme toggle button, default light -- see dashboard.css for
 * the [data-theme] styling this drives on <html>. Remembers the visitor's
 * choice via localStorage (own key, not shared with /spm/'s spmd-theme --
 * these are two unrelated dashboards on this site), but every first-ever
 * visit starts light. */
export function renderThemeToggle() {
  const theme = storedTheme() === "dark" ? "dark" : "light";
  applyTheme(theme);

  const label = (t) => (t === "dark" ? "☀️ Light mode" : "🌙 Dark mode");
  const button = html`<button type="button" class="bridge-theme-toggle">${label(theme)}</button>`;
  button.setAttribute("aria-pressed", String(theme === "dark"));
  button.addEventListener("click", () => {
    const next = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
    applyTheme(next);
    button.setAttribute("aria-pressed", String(next === "dark"));
    button.textContent = label(next);
  });
  return button;
}
