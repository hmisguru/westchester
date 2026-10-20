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
 * e.g. no Problem Solving/Diversion events that month) as an explicit empty
 * state rather than showing a misleading 0%.
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

export function renderOutcomeRateTiles(doc, monthIndex) {
  const month = doc.months[monthIndex];
  const prevMonth = monthIndex > 0 ? doc.months[monthIndex - 1] : null;
  const wrap = el("div", "ce-row ce-row-metrics");
  wrap.append(
    renderRateTile(
      "Problem Solving/Diversion Success Rate",
      month,
      prevMonth,
      "psd_rate",
      "psd_total",
      "No Problem Solving/Diversion events recorded this month."
    )
  );
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

const OTHER_EVENT_LABEL = "Other";

/**
 * CE Events, stacked by month across the whole fiscal year -- raw event
 * occurrences, not deduplicated by household (see sql/ce_event_mix.sql's own
 * header comment). Only the top 7 event types by FY-wide total get their own
 * stack segment and legend entry; everything else folds into "Other" --
 * the dataviz skill's own non-negotiable ("a 9th series is never a generated
 * hue; it folds into 'Other'") applies directly here, since the 8-color
 * validated palette can't give each of the 18 Event codes its own identity
 * without reusing hues. "Other" gets a neutral gray (var(--ce-muted)), not a
 * 9th palette color, so it reads as a catch-all rather than a real category.
 */
/**
 * Shared plotting logic for every "stacked by month across the FY" chart on
 * this page (CE Events, Referral Outcomes): a stacked Plot.barY (same
 * Plot.barY(Plot.stackY(...)) pattern bridge.js's own renderAgeHistogram
 * uses in the sibling hmisguru/baltimore repo), with the selected month
 * highlighted by the same dashed rule renderTrend()'s line chart uses.
 *
 * No x-axis title: Plot auto-synthesizes one from the x channel's own field
 * name ("month") if label isn't explicitly set to null (not just omitted) --
 * the tick labels are already month names, so no title is needed.
 */
function renderStackedByMonth(rows, months, selected, categoryField, valueField, domain, range, yLabel) {
  return resize((width) =>
    Plot.plot({
      width,
      height: 320,
      marginBottom: 40,
      x: {label: null, tickRotate: -35, domain: months.map((m) => m.label)},
      y: {label: yLabel, grid: true, nice: true},
      color: {domain, range, legend: true},
      marks: [
        Plot.ruleY([0]),
        Plot.barY(
          rows,
          Plot.stackY({
            x: "month",
            y: valueField,
            fill: categoryField,
            order: domain,
            title: (d) => `${d[categoryField]}: ${integer.format(d[valueField])} (${d.month})`,
          })
        ),
        Plot.ruleX([selected.label], {stroke: "currentColor", strokeOpacity: 0.4, strokeDasharray: "4,3"}),
      ],
    })
  );
}

export function renderEventMixChart(doc, monthIndex) {
  const months = doc.months;
  const selected = months[monthIndex];

  const totals = new Map();
  for (const m of months) {
    for (const e of m.by_event) {
      totals.set(e.event, (totals.get(e.event) ?? 0) + e.events);
    }
  }
  const grandTotal = [...totals.values()].reduce((s, v) => s + v, 0);

  const card = el("div", "ce-card");
  card.append(el("h3", "ce-card-title", `CE Events by Month -- ${doc.fiscal_year.label}`));
  if (!grandTotal) {
    card.append(el("p", "ce-empty", "No CE events recorded this fiscal year."));
    return card;
  }

  const topEvents = [...totals.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 7)
    .map(([event]) => event);
  const domain = [...topEvents, OTHER_EVENT_LABEL];
  const range = [...SERIES.slice(0, topEvents.length), "var(--ce-muted)"];

  const rows = months.flatMap((m) => {
    const byEvent = new Map(m.by_event.map((e) => [e.event, e.events]));
    const other = [...byEvent.entries()]
      .filter(([event]) => !topEvents.includes(event))
      .reduce((s, [, v]) => s + v, 0);
    return [
      ...topEvents.map((event) => ({month: m.label, event, events: byEvent.get(event) ?? 0})),
      {month: m.label, event: OTHER_EVENT_LABEL, events: other},
    ];
  });

  card.append(renderStackedByMonth(rows, months, selected, "event", "events", domain, range, "CE Events"));
  return card;
}

// Successful/Unsuccessful/No-result -- only 4 fixed categories, all of
// which fit the validated palette directly, so (unlike Event Mix's 18) no
// top-K-plus-"Other" folding is needed here.
const OUTCOME_COLORS = SERIES.slice(0, 4);

export function renderReferralOutcomesChart(doc, monthIndex) {
  const months = doc.months;
  const selected = months[monthIndex];
  const domain = months[0].by_outcome.map((o) => o.outcome);

  const grandTotal = months.reduce((s, m) => s + m.by_outcome.reduce((s2, o) => s2 + o.events, 0), 0);
  const card = el("div", "ce-card");
  card.append(el("h3", "ce-card-title", `Referral Outcomes by Month -- ${doc.fiscal_year.label}`));
  if (!grandTotal) {
    card.append(el("p", "ce-empty", "No CE referrals recorded this fiscal year."));
    return card;
  }

  const rows = months.flatMap((m) => m.by_outcome.map((o) => ({month: m.label, outcome: o.outcome, events: o.events})));
  card.append(renderStackedByMonth(rows, months, selected, "outcome", "events", domain, OUTCOME_COLORS, "Referrals"));
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
