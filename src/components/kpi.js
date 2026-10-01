// KPI stat tile: plain DOM, no dependencies, so it renders the same inside an
// Observable page, an iframe, or a third-party site embedding it.
//
// Neutral default styling (slate text, deep blue accent, system font stack) --
// no branding is assumed for the embedding site. Host sites can restyle it
// through the --wkpi-* custom properties below.
//
// Light by default. data-theme="dark" forces the dark variant; data-theme="auto"
// follows the OS setting.

const STYLE_ID = "wkpi-style";

const DARK = `
    --wkpi-surface: #1b2430;
    --wkpi-border: #334155;
    --wkpi-accent: #60a5fa;
    --wkpi-text: #ffffff;
    --wkpi-text-secondary: #cbd5e1;
    --wkpi-eyebrow: #60a5fa;
    --wkpi-good: #4ade80;
    --wkpi-bad: #f87171;
    --wkpi-neutral: #94a3b8;`;

const CSS = `
.wkpi {
  --wkpi-surface: #ffffff;
  --wkpi-border: #e2e8f0;
  --wkpi-accent: #2563eb;
  --wkpi-text: #0f172a;
  --wkpi-text-secondary: #475569;
  --wkpi-eyebrow: #1d4ed8;
  --wkpi-good: #15803d;
  --wkpi-bad: #b91c1c;
  --wkpi-neutral: #64748b;
  box-sizing: border-box;
  display: flex;
  flex-direction: column;
  gap: 8px;
  min-width: 0;
  padding: 20px 24px;
  border: 1px solid var(--wkpi-border);
  border-top: 4px solid var(--wkpi-accent);
  border-radius: 12px;
  background: var(--wkpi-surface);
  color: var(--wkpi-text);
  font-family: var(--wkpi-font, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif);
  line-height: 1.3;
}
.wkpi[data-theme="dark"] {${DARK}
}
@media (prefers-color-scheme: dark) {
  .wkpi[data-theme="auto"] {${DARK}
  }
}
.wkpi * { box-sizing: border-box; }
.wkpi-measure {
  font-size: 13px;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--wkpi-eyebrow);
}
.wkpi-title { margin: 0; font-family: inherit; font-size: 18px; font-weight: 400; line-height: 1.3; color: var(--wkpi-text); }
.wkpi-value { font-size: 44px; font-weight: 700; line-height: 1.05; letter-spacing: -0.01em; }
.wkpi-unit { font-size: 20px; font-weight: 400; color: var(--wkpi-text-secondary); margin-left: 4px; }
.wkpi-delta { display: flex; flex-wrap: wrap; align-items: baseline; align-content: flex-start; gap: 4px 8px; font-size: 15px; }
.wkpi-arrow { font-size: 13px; }
.wkpi-delta[data-status="improved"] .wkpi-arrow { color: var(--wkpi-good); }
.wkpi-delta[data-status="worsened"] .wkpi-arrow { color: var(--wkpi-bad); }
.wkpi-delta[data-status="unchanged"] .wkpi-arrow,
.wkpi-delta[data-status="neutral"] .wkpi-arrow { color: var(--wkpi-neutral); }
.wkpi-status { font-weight: 700; }
.wkpi-change { color: var(--wkpi-text-secondary); }
.wkpi-description { margin: 4px 0 0; font-size: 14px; line-height: 1.4; color: var(--wkpi-text-secondary); }
.wkpi-footer { margin-top: auto; padding-top: 12px; border-top: 1px solid var(--wkpi-border); font-size: 12px; color: var(--wkpi-text-secondary); }
.wkpi-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(280px, 100%), 1fr));
  gap: 16px;
}
/* In a grid, each tile's parts (label, title, value, change, description)
   become rows of the parent grid via subgrid, so they line up across tiles
   in the same row even when titles wrap to different lengths. Browsers
   without subgrid fall back to the tile's normal stacked layout. */
@supports (grid-template-rows: subgrid) {
  .wkpi-grid > .wkpi {
    display: grid;
    grid-template-rows: subgrid;
    row-gap: 8px;
    align-content: start;
  }
}
.wkpi-grid-wrapper {
  --wkpi-footer-text: #475569;
}
.wkpi-grid-wrapper[data-theme="dark"] {
  --wkpi-footer-text: #cbd5e1;
}
@media (prefers-color-scheme: dark) {
  .wkpi-grid-wrapper[data-theme="auto"] {
    --wkpi-footer-text: #cbd5e1;
  }
}
.wkpi-grid-footer {
  margin-top: 12px;
  font-family: var(--wkpi-font, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif);
  font-size: 13px;
  color: var(--wkpi-footer-text);
}
`;

function ensureStyle(root = document) {
  const host = root.head ?? root;
  if (host.querySelector?.(`#${STYLE_ID}`)) return;
  const style = document.createElement("style");
  style.id = STYLE_ID;
  style.textContent = CSS;
  host.append(style);
}

const integer = new Intl.NumberFormat("en-US", {maximumFractionDigits: 0});
const oneDecimal = new Intl.NumberFormat("en-US", {minimumFractionDigits: 1, maximumFractionDigits: 1});

function formatValue(kpi) {
  switch (kpi.format) {
    case "percent": return {value: oneDecimal.format(kpi.value), unit: kpi.unit ?? "%"};
    case "days": return {value: integer.format(kpi.value), unit: kpi.unit ?? "days"};
    default: return {value: integer.format(kpi.value), unit: kpi.unit ?? ""};
  }
}

// Plain-language change vs. the prior year, e.g. "116 fewer than FY2025".
function describeChange(kpi, previousLabel) {
  const diff = kpi.value - kpi.previous;
  const up = diff > 0;
  let amount;
  let word;
  switch (kpi.format) {
    case "percent":
      amount = `${oneDecimal.format(Math.abs(diff))} pts`;
      word = up ? "higher" : "lower";
      break;
    case "days":
      amount = `${integer.format(Math.abs(diff))} ${Math.round(Math.abs(diff)) === 1 ? "day" : "days"}`;
      word = up ? "longer" : "shorter";
      break;
    default:
      amount = integer.format(Math.abs(diff));
      word = up ? "more" : "fewer";
  }
  return `${amount} ${word} than ${previousLabel}`;
}

function statusOf(kpi) {
  const diff = kpi.value - kpi.previous;
  // Treat changes that round to zero at display precision as unchanged.
  const epsilon = kpi.format === "percent" ? 0.05 : 0.5;
  if (Math.abs(diff) < epsilon) return "unchanged";
  // No better direction (e.g. Street Outreach exits): report the change only.
  if (!kpi.better) return "neutral";
  return (diff < 0) === (kpi.better === "lower") ? "improved" : "worsened";
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function formatFiscalYear(fy) {
  const month = (iso) =>
    new Date(`${iso}T12:00:00`).toLocaleDateString("en-US", {month: "short", year: "numeric"});
  return `${fy.label} (${month(fy.start)} – ${month(fy.end)})`;
}

function footerText(data) {
  return [formatFiscalYear(data.fiscal_year), data.source].filter(Boolean).join(" · ");
}

/**
 * Render one KPI tile.
 * @param {object} data   the parsed spm.json document
 * @param {object} kpi    one entry of data.kpis
 * @param {object} [options]
 * @param {"light"|"dark"|"auto"} [options.theme="light"]  "auto" follows the OS
 * @param {boolean} [options.description=true]  show the one-line definition
 * @param {boolean} [options.footer=true]  show fiscal year + source line
 */
export function renderKpi(data, kpi, {theme = "light", description = true, footer = true} = {}) {
  ensureStyle();
  const tile = el("article", "wkpi");
  tile.dataset.theme = theme;
  tile.dataset.kpi = kpi.id;

  tile.append(el("div", "wkpi-measure", `HUD ${kpi.measure}`));
  tile.append(el("h3", "wkpi-title", kpi.title));

  const {value, unit} = formatValue(kpi);
  const valueNode = el("div", "wkpi-value", value);
  if (unit) valueNode.append(el("span", "wkpi-unit", unit));
  tile.append(valueNode);

  if (kpi.previous != null) {
    const status = statusOf(kpi);
    const delta = el("div", "wkpi-delta");
    delta.dataset.status = status;
    const arrow = kpi.value > kpi.previous ? "▲" : kpi.value < kpi.previous ? "▼" : "●";
    delta.append(el("span", "wkpi-arrow", arrow));
    delta.lastChild.setAttribute("aria-hidden", "true");
    const label = {improved: "Improved", worsened: "Worsened", unchanged: "No change"}[status];
    if (label) delta.append(el("span", "wkpi-status", label));
    delta.append(el("span", "wkpi-change", describeChange(kpi, data.previous_fiscal_year.label)));
    tile.append(delta);
  }

  if (description) tile.append(el("p", "wkpi-description", kpi.description));
  if (footer) tile.append(el("div", "wkpi-footer", footerText(data)));
  return tile;
}

/**
 * Render several KPI tiles in a responsive grid (all of them by default).
 * The fiscal year + source line is shown once below the grid rather than on
 * every tile; pass {footer: false} to omit it.
 *
 * @param {object} [options]  renderKpi options
 */
export function renderKpiGrid(data, ids, {footer = true, ...options} = {}) {
  ensureStyle();
  const wrapper = el("div", "wkpi-grid-wrapper");
  wrapper.dataset.theme = options.theme ?? "light";
  const grid = el("div", "wkpi-grid");
  const footerNode = el("div", "wkpi-grid-footer");

  grid.replaceChildren(...(ids ?? data.kpis.map((d) => d.id)).map((id) => {
    const tile = renderKpi(data, findKpi(data, id), {...options, footer: false});
    // One parent-grid row per tile part, for the subgrid alignment above.
    tile.style.gridRow = `span ${tile.children.length}`;
    return tile;
  }));
  footerNode.textContent = footerText(data);

  wrapper.append(grid);
  if (footer) wrapper.append(footerNode);
  return wrapper;
}

export function findKpi(data, id) {
  const kpi = data.kpis.find((d) => d.id === id);
  if (!kpi) throw new Error(`Unknown KPI "${id}". Available: ${data.kpis.map((d) => d.id).join(", ")}`);
  return kpi;
}
