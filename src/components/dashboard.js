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
import {html} from "npm:htl";
import * as Inputs from "npm:@observablehq/inputs";
import {hierarchy, treemap as d3treemap} from "npm:d3-hierarchy";
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
    range: segments.map((s, i) => slices[s]?.color ?? SERIES[i % SERIES.length]),
    legend: true
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
// of page background, so these never need a dark variant.
const STATUS_COLORS = {green: "#0a6e0a", red: "#b3261e"};

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

function renderWidget(dashboard, widget, filterValues) {
  const rows = widgetRows(dashboard, widget, filterValues);
  let body;
  if (widget.type === "text") body = renderText(widget);
  else if (widget.type === "metric") body = renderMetric(widget, rows);
  else if (widget.type === "table") body = renderTable(widget, rows);
  else if (!rows.length) body = empty();
  else if (widget.chart === "line") body = widget.name === LENGTH_OF_TIME_WIDGET_NAME ? renderLengthOfTimeChart(widget, rows) : renderLine(widget, rows);
  else if (widget.chart === "bar") body = renderBar(widget, rows);
  else if (widget.chart === "pie") body = renderPie(widget, rows);
  else if (widget.chart === "treemap") body = renderTreemap(widget, rows);
  else body = html`<p class="bridge-empty">Unsupported widget type: ${widget.chart ?? widget.type}</p>`;

  const isNote = widget.type === "text";
  const span = widget.col ?? 12;
  return html`<section class="bridge-card${isNote ? " bridge-note" : ""}${widget.type === "metric" ? " bridge-card-metric" : ""}" style="--span:${span}" data-widget=${widget.id}>
    ${isNote ? null : html`<h3 class="bridge-card-title">${widget.name}</h3>`}
    ${body}
  </section>`;
}

/** All rows of one tab, laid out on the dashboard's 12-column grid. */
export function renderTab(dashboard, tabName, filterValues) {
  const tab = dashboard.tabs.find((t) => t.name === tabName) ?? dashboard.tabs[0];
  return html`<div class="bridge-tab">${tab.rows.map((row) => html`
    <div class="bridge-row">${row.map((w) => renderWidget(dashboard, w, filterValues))}</div>
  `)}</div>`;
}

// The dashboard's one untabbed note ("Dashboard Notes"), shown above the
// filters: its opening text spans the panel, and its "### " sections
// (Household Type / Project Type filter definitions) sit side by side below
// it, matching this widget's own front-loaded structure in dashboard.yml.
export function renderAbout(dashboard) {
  return html`<section class="bridge-about" aria-label="About this dashboard">${dashboard.notes.map((w) => {
    const [intro, ...sections] = (w.content ?? "").split(/^\*\*([^*]+:)\*\*/m);
    const block = (md, cls) => {
      const div = html`<div class=${cls}>`;
      div.innerHTML = marked.parse(md);
      return div;
    };
    // dashboard.yml's own notes widget uses **Bold labels:** for its
    // filter-definition paragraphs, so the intro/terms split works
    // differently here than a "### "-heading-based note would: everything
    // up to the first such bold label is the intro, and each bold label plus
    // the text immediately after it becomes its own side-by-side term.
    const terms = [];
    for (let i = 0; i < sections.length; i += 2) terms.push(`**${sections[i]}**${sections[i + 1] ?? ""}`);
    return html`<div class="bridge-about-note">
      ${intro.trim() ? block(intro, "bridge-text bridge-about-intro") : null}
      ${terms.length ? html`<div class="bridge-about-terms">${terms.map((t) => block(t, "bridge-text bridge-about-term"))}</div>` : null}
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
  const tabs = Inputs.radio(tabNames, {value: match(tabNames, initial.tab) ?? tabNames[0]});
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
