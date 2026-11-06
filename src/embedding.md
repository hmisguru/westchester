---
title: Embedding guide
---

```js
const spm = FileAttachment("./data/spm.json").json();
// This site's own base URL, so the snippets below are copy-and-paste ready.
const base = new URL(".", location.href).href;
```

# Embedding the KPIs

There are three ways to put these KPIs on another website. All of them update automatically when this site is rebuilt each month.

## 1. Iframe (simplest)

Works anywhere you can paste HTML, including most website builders and CMSs.

```js
display(html`<pre><code>${`<iframe src="${base}embed/exits-to-permanent-housing"
  title="Exits to permanent destinations"
  width="360" height="340" style="border:0"></iframe>`}</code></pre>`);
```

Use `embed/all` for every KPI in a responsive grid (give it a height of about 630px on desktop; it needs more on narrower screens, where the tiles stack). Tiles are light by default. Add `?theme=dark` for the dark variant, or `?theme=auto` to follow the viewer's system setting.

Available KPI pages:

```js
display(html`<ul>${spm.kpis.map((d) => html`<li><a href="./embed/${d.id}"><code>embed/${d.id}</code></a> — ${d.title}</li>`)}</ul>`);
```

## 2. JavaScript module (no iframe)

Renders the tiles directly into your page, so they inherit your layout and width. Your page needs to allow ES module scripts.

```js
display(html`<pre><code>${`<div id="westchester-kpis"></div>
<script type="module">
  import {KPIGrid} from "${base}kpis.js";
  document.querySelector("#westchester-kpis").append(await KPIGrid());
<\/script>`}</code></pre>`);
```

The module exports:

- `KPIGrid(ids?, options?)`: a responsive grid, all KPIs by default, or pass an array of ids such as `["length-of-time-homeless", "first-time-homeless-with-outreach"]`.
- `KPI(id, options?)`: a single tile.
- `data()`: the underlying numbers, for building your own display.

Options: `{theme: "light" | "dark" | "auto", description: false, footer: false}`. The default is `"light"`.

The tiles use a neutral default style (no branding assumed). To adapt them to your site, override these CSS custom properties on `.wkpi`: `--wkpi-font`, `--wkpi-surface`, `--wkpi-border`, `--wkpi-accent` (top stripe), `--wkpi-eyebrow` (measure label), `--wkpi-text`, `--wkpi-text-secondary`, `--wkpi-good`, `--wkpi-bad`, `--wkpi-neutral`.

## 3. Raw JSON

For anything else (a chart library, a report generator, another dashboard):

```js
display(html`<pre><code>${`${base}data/spm.json`}</code></pre>`);
```

## KPI definitions

```js
display(Inputs.table(spm.kpis.map((d) => ({id: d.id, measure: d.measure, title: d.title, definition: d.description})), {layout: "auto", rows: 12}));
```

# Embedding the full System Performance Dashboard

The [full dashboard](./spm/) shows every HUD System Performance Measure (all 9 widgets), not just the 5 summarized above as KPI tiles. It has its own, narrower embedding surface — no JS module, since a 9-table dashboard doesn't fit a single-tile component.

## Iframe

```js
display(html`<pre><code>${`<iframe src="${base}embed/spm"
  title="Westchester CoC System Performance Dashboard"
  width="900" height="1400" style="border:0"></iframe>`}</code></pre>`);
```

Give it a generous height — it's 9 tables stacked, not one tile; adjust to taste depending on how much of it you want visible without scrolling. Light by default. Add `?theme=dark`, or `?theme=auto` to follow the viewer's system setting.

## Raw JSON

```js
display(html`<pre><code>${`${base}data/spm-dashboard.json`}</code></pre>`);
```

Every widget's rows, columns, and the current/previous fiscal year this build covers — the same data the iframe above renders.
