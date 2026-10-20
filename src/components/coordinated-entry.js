// Coordinated Entry dashboard (/coordinated-entry/).
//
// Unlike every other full-page dashboard on this site (/bridge/, /spm/),
// this one has no DAC YAML behind it -- see src/data/coordinated-entry.json.py
// and CLAUDE.md's Coordinated Entry section. It's also the only dashboard
// here built around MONTHLY granularity (a 12-point FY2026 trend + a month
// slider) rather than a single fiscal-year or quarter-over-quarter
// comparison, per explicit request.
//
// Class prefix "ce-" throughout, matching this page's own /coordinated-entry/
// route.

import * as Plot from "npm:@observablehq/plot";
import {html} from "npm:htl";
import {resize} from "observablehq:stdlib";

// Validated categorical palette (dataviz skill reference instance), same
// var(--series-N) convention as /bridge/'s own dashboard.js -- coordinated-
// entry.css defines the light steps on :root and redefines them under
// html[data-theme="dark"], so toggling the theme recolors every chart with
// no re-render.
const SERIES = [1, 2, 3, 4, 5, 6, 7, 8].map((n) => `var(--series-${n})`);

const integer = new Intl.NumberFormat("en-US", {maximumFractionDigits: 0});

// Must match CHART_OUTCOMES in src/data/coordinated-entry.json.py exactly.
const CHART_OUTCOMES = ["Successful", "Unsuccessful: client rejected", "Unsuccessful: provider rejected", "No result recorded"];

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

/** One stat tile: a big number, with month-over-month change if a prior month exists. */
function renderStatTile(label, month, prevMonth, field) {
  const tile = el("div", "ce-card ce-card-metric");
  tile.append(el("h3", "ce-card-title", label));
  tile.append(el("div", "ce-metric", integer.format(month[field])));
  if (prevMonth) {
    const diff = month[field] - prevMonth[field];
    const change = el("div", "ce-change");
    const arrow = diff > 0 ? "▲" : diff < 0 ? "▼" : "●";
    change.append(el("span", "ce-change-arrow", arrow));
    // Neither direction is inherently better here: more people reaching CE
    // can mean more outreach activity or more need, same reasoning as this
    // site's own "People in Street Outreach..." KPI tile (kpi.js) -- a
    // neutral arrow + plain description, no Improved/Worsened label.
    change.append(
      document.createTextNode(
        ` ${integer.format(Math.abs(diff))} ${diff >= 0 ? "more" : "fewer"} than ${prevMonth.label}`
      )
    );
    tile.append(change);
  } else {
    tile.append(el("div", "ce-change ce-change-empty", "First month of FY -- no prior month to compare."));
  }
  return tile;
}

export function renderReachTiles(doc, monthIndex) {
  const month = doc.months[monthIndex];
  const prevMonth = monthIndex > 0 ? doc.months[monthIndex - 1] : null;
  const wrap = el("div", "ce-row ce-row-metrics");
  wrap.append(renderStatTile("Persons with a CE Assessment", month, prevMonth, "persons"));
  wrap.append(renderStatTile("Households with a CE Assessment", month, prevMonth, "households"));
  return wrap;
}

const oneDecimal = new Intl.NumberFormat("en-US", {minimumFractionDigits: 1, maximumFractionDigits: 1});

/**
 * A percentage stat tile, better: "higher" (unlike renderStatTile's reach
 * tiles, a successful-referral rate genuinely is better when it's up) --
 * Improved/Worsened labeled, same convention kpi.js's own statusOf() uses
 * site-wide. Handles a null rate (the month's own denominator was zero --
 * e.g. no residential referrals that month) as an explicit empty state
 * rather than showing a misleading 0%.
 */
function renderRateTile(label, month, prevMonth, rateField, totalField, noDataMessage) {
  const tile = el("div", "ce-card ce-card-metric");
  tile.append(el("h3", "ce-card-title", label));
  const rate = month[rateField];
  if (rate == null) {
    tile.append(el("div", "ce-metric", "—"));
    tile.append(el("div", "ce-change ce-change-empty", noDataMessage));
    return tile;
  }
  tile.append(el("div", "ce-metric", `${oneDecimal.format(rate)}%`));
  const prevRate = prevMonth?.[rateField];
  if (prevRate != null) {
    const diff = rate - prevRate;
    const change = el("div", "ce-change");
    const epsilon = 0.05;
    const status = Math.abs(diff) < epsilon ? "unchanged" : diff > 0 ? "improved" : "worsened";
    const arrow = status === "unchanged" ? "●" : status === "improved" ? "▲" : "▼";
    change.dataset.status = status;
    change.append(el("span", "ce-change-arrow", arrow));
    const statusLabel = {improved: "Improved", worsened: "Worsened", unchanged: "No change"}[status];
    change.append(el("span", "ce-change-status", statusLabel));
    change.append(
      document.createTextNode(` ${oneDecimal.format(Math.abs(diff))} pts than ${prevMonth.label}`)
    );
    tile.append(change);
  } else if (prevMonth) {
    tile.append(el("div", "ce-change ce-change-empty", `No referrals in ${prevMonth.label} to compare against.`));
  } else {
    tile.append(el("div", "ce-change ce-change-empty", "First month of FY -- no prior month to compare."));
  }
  return tile;
}

// Problem Solving/Diversion Success Rate was removed per explicit request
// (its own rate tile, not just a display tweak) -- see
// sql/ce_referral_outcomes.sql's own header comment for what's still
// computed here vs. not.
export function renderResidentialRateTile(doc, monthIndex) {
  const month = doc.months[monthIndex];
  const prevMonth = monthIndex > 0 ? doc.months[monthIndex - 1] : null;
  const wrap = el("div", "ce-row ce-row-metrics");
  wrap.append(
    renderRateTile(
      "Referral to Residential Success Rate",
      month,
      prevMonth,
      "residential_rate",
      "residential_total",
      "No residential referrals recorded this month."
    )
  );
  return wrap;
}

const pct = new Intl.NumberFormat("en-US", {style: "percent", maximumFractionDigits: 0});

/**
 * A sorted-horizontal-bars breakdown chart (lengths compare more accurately
 * than angles -- same reasoning /bridge/'s own renderPie uses), shared by
 * every "mix for the selected month" chart on this page.
 */
function renderSortedBarChart(title, rows, labelField, valueField, emptyMessage) {
  const sorted = [...rows].sort((a, b) => b[valueField] - a[valueField]);
  const total = sorted.reduce((s, d) => s + d[valueField], 0);
  // Reserve enough left margin for the longest label actually being shown
  // (e.g. Event Mix's "Referral to CE Housing Needs Assessment") rather than
  // a single fixed width -- a cap tuned for the 4-category charts clipped
  // the longer Event Mix labels, confirmed live.
  const longestLabel = Math.max(...sorted.map((d) => String(d[labelField]).length));

  const card = el("div", "ce-card");
  card.append(el("h3", "ce-card-title", title));
  if (!total) {
    card.append(el("p", "ce-empty", emptyMessage));
    return card;
  }
  card.append(
    resize((width) =>
      Plot.plot({
        width,
        height: 40 + sorted.length * 36,
        marginLeft: Math.min(20 + longestLabel * 6.2, width * 0.45),
        marginRight: 90,
        x: {axis: null},
        y: {domain: sorted.map((d) => d[labelField]), label: null, tickSize: 0},
        marks: [
          Plot.barX(sorted, {y: labelField, x: valueField, fill: SERIES[0], rx: 2, insetTop: 6, insetBottom: 6}),
          Plot.text(sorted, {
            y: labelField,
            x: valueField,
            text: (d) => `${integer.format(d[valueField])} (${pct.format(d[valueField] / total)})`,
            textAnchor: "start",
            dx: 6,
            fill: "currentColor",
          }),
        ],
      })
    )
  );
  return card;
}

export function renderHouseholdTypeChart(doc, monthIndex) {
  const month = doc.months[monthIndex];
  return renderSortedBarChart(
    `Household Type -- ${month.label}`,
    month.by_household_type,
    "household_type",
    "persons",
    "No CE assessments recorded this month."
  );
}

export function renderAccessChannelChart(doc, monthIndex) {
  const month = doc.months[monthIndex];
  return renderSortedBarChart(
    `Access Channel -- ${month.label}`,
    month.by_channel,
    "channel",
    "households",
    "No CE assessments recorded this month."
  );
}

// Successful/Unsuccessful/No-result -- only 4 fixed categories, all of
// which fit the validated palette directly, so no top-K-plus-"Other"
// folding is needed here.
const OUTCOME_COLORS = SERIES.slice(0, 4);

// Display-only short forms for the x-axis tick labels, since a rotated full
// label ("Referral to Prevention Assistance project", 43 chars) climbs far
// enough up its own diagonal to be painted over by the bars above it --
// confirmed live via getBoundingClientRect() on the rendered SVG, not
// guessed. Shortening the labels (every category here is a referral, so the
// repeated "Referral to" prefix carries no information on this axis) lets
// the chart drop rotation entirely; the full name still appears in the
// legend and the per-segment hover tooltip.
const SHORT_EVENT_LABELS = {
  "Referral to Prevention Assistance project": "Prevention Assistance",
  "Referral to RRH opening": "RRH opening",
  "Referral to PSH opening": "PSH opening",
  "Referral to Other PH project": "Other PH project",
};

/**
 * CE Events by Outcome, per explicit request to combine what were
 * previously two separate "stacked by month" charts (CE Events, Referral
 * Outcomes) into one: each bar is now a CE event rather than a month, each
 * stacked by referral outcome. Whole-FY totals (summed across all 12
 * months), not filtered by the slider -- this chart's x-axis is no longer
 * months, so there's no "selected month" to highlight.
 *
 * Scoped to 4 events, per explicit request (RRH/PSH/Other PH openings, plus
 * Prevention Assistance, added back on a follow-up after initially being
 * dropped) -- see sql/ce_referral_outcomes.sql's own event_outcomes CTE.
 */
export function renderEventOutcomesChart(doc) {
  const totals = new Map();
  for (const m of doc.months) {
    for (const row of m.by_event_outcome) {
      const key = `${row.event}|${row.outcome}`;
      totals.set(key, (totals.get(key) ?? 0) + row.events);
    }
  }
  const eventTotals = new Map();
  for (const row of [...totals.entries()].map(([key, events]) => ({event: key.split("|")[0], events}))) {
    eventTotals.set(row.event, (eventTotals.get(row.event) ?? 0) + row.events);
  }
  const grandTotal = [...eventTotals.values()].reduce((s, v) => s + v, 0);

  const card = el("div", "ce-card");
  card.append(el("h3", "ce-card-title", `CE Events by Outcome -- ${doc.fiscal_year.label}`));
  if (!grandTotal) {
    card.append(el("p", "ce-empty", "No referrals recorded this fiscal year for these events."));
    return card;
  }

  const eventDomain = [...eventTotals.entries()]
    .sort((a, b) => b[1] - a[1])
    .map(([event]) => SHORT_EVENT_LABELS[event] ?? event);
  const outcomeDomain = CHART_OUTCOMES;
  const rows = [...totals.entries()].map(([key, events]) => {
    const [event, outcome] = key.split("|");
    return {event, shortEvent: SHORT_EVENT_LABELS[event] ?? event, outcome, events};
  });

  card.append(
    resize((width) =>
      Plot.plot({
        width,
        height: 320,
        marginBottom: 40,
        x: {label: null, domain: eventDomain},
        y: {label: "Referrals", grid: true, nice: true},
        color: {domain: outcomeDomain, range: OUTCOME_COLORS, legend: true},
        marks: [
          Plot.ruleY([0]),
          Plot.barY(
            rows,
            Plot.stackY({
              x: "shortEvent",
              y: "events",
              fill: "outcome",
              order: outcomeDomain,
              title: (d) => `${d.event} -- ${d.outcome}: ${integer.format(d.events)}`,
            })
          ),
        ],
      })
    )
  );
  return card;
}

/** The 12-month FY trend, with the slider's selected month highlighted. */
export function renderTrend(doc, monthIndex) {
  const months = doc.months;
  const selected = months[monthIndex];
  const card = el("div", "ce-card");
  card.append(el("h3", "ce-card-title", `Persons Assessed by Month -- ${doc.fiscal_year.label}`));
  card.append(
    resize((width) =>
      Plot.plot({
        width,
        height: 220,
        marginBottom: 40,
        // label: null, not omitted -- Plot auto-synthesizes an axis title
        // from the channel's own field name ("label") otherwise, which
        // collided with the rotated Apr/May tick labels just as badly as an
        // explicit "Month" title did. The tick labels are already month
        // names, so no title is needed at all.
        x: {label: null, tickRotate: -35, domain: months.map((m) => m.label)},
        y: {label: "Persons assessed", grid: true, nice: true},
        marks: [
          Plot.ruleY([0]),
          Plot.line(months, {x: "label", y: "persons", stroke: SERIES[0], strokeWidth: 2}),
          Plot.dot(months, {x: "label", y: "persons", fill: SERIES[0], r: 3}),
          Plot.ruleX([selected.label], {stroke: "currentColor", strokeOpacity: 0.4, strokeDasharray: "4,3"}),
          Plot.dot([selected], {x: "label", y: "persons", fill: "currentColor", r: 5}),
          Plot.tip(
            months,
            Plot.pointerX({x: "label", y: "persons", title: (d) => `${d.label}: ${integer.format(d.persons)} persons assessed`})
          ),
        ],
      })
    )
  );
  return card;
}

/**
 * A single <input type="range"> over the 12 months of the fiscal year,
 * defaulting to the most recent (rightmost) month -- same convention as this
 * site's sibling sites' own quarter/month pickers. Calls onChange(index) on
 * every move and renders the current month's label beside the slider.
 */
export function renderMonthSlider(doc, onChange) {
  const months = doc.months;
  const wrap = el("div", "ce-slider-wrap");
  const labelEl = el("span", "ce-slider-label", months[months.length - 1].label);
  const input = document.createElement("input");
  input.type = "range";
  input.className = "ce-slider";
  input.min = "0";
  input.max = String(months.length - 1);
  input.step = "1";
  input.value = String(months.length - 1);
  input.setAttribute("aria-label", "Select month");
  input.addEventListener("input", () => {
    const index = Number(input.value);
    labelEl.textContent = months[index].label;
    onChange(index);
  });
  wrap.append(el("label", "ce-slider-text", "Month:"), input, labelEl);
  return {wrap, input};
}

const THEME_KEY = "ce-theme";

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

/** A light/dark theme toggle button, default light -- see coordinated-entry.css
 * for the [data-theme] styling this drives on <html>. Own localStorage key
 * (ce-theme), not shared with /bridge/'s bridge-theme or /spm/'s spmd-theme. */
export function renderThemeToggle() {
  const theme = storedTheme() === "dark" ? "dark" : "light";
  applyTheme(theme);

  const label = (t) => (t === "dark" ? "☀️ Light mode" : "🌙 Dark mode");
  const button = html`<button type="button" class="ce-theme-toggle">${label(theme)}</button>`;
  button.setAttribute("aria-pressed", String(theme === "dark"));
  button.addEventListener("click", () => {
    const next = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
    applyTheme(next);
    button.setAttribute("aria-pressed", String(next === "dark"));
    button.textContent = label(next);
  });
  return button;
}

const eastern = (iso, options) => new Date(iso).toLocaleString("en-US", {timeZone: "America/New_York", ...options});

/** "Data through <FY end> · HMIS export dated <export_end> · Dashboard refreshed <generated>." */
export function renderFootnote(doc) {
  return html`<p class="ce-footnote">Data through ${doc.fiscal_year.end} · HMIS export dated ${doc.export_end} · Dashboard refreshed ${eastern(doc.generated, {dateStyle: "medium", timeStyle: "short"})}.</p>`;
}
