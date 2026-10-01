# westchester-kpis

Embeddable KPIs for the Westchester County Continuum of Care (NY-604), built from HMIS data with [Observable Framework](https://observablehq.com/framework/) and published on GitHub Pages at **https://hmisguru.github.io/westchester-kpis/**.

## KPIs

Seven KPIs for the most recent complete federal fiscal year (Oct 1 – Sep 30) compared with the year before -- six are official HUD System Performance Measures, one (`people-in-street-outreach`) is a dashboard-only addition:

| id | Measure | KPI |
|---|---|---|
| `length-of-time-homeless` | 1a | Average length of time homeless (ES + Safe Haven) |
| `returns-to-homelessness` | 2 | People returning to homelessness within 2 years of exiting to permanent housing |
| `people-sheltered` | 3.2 | Unduplicated people in ES or TH |
| `first-time-homeless` | 5.1 | People homeless for the first time (no activity in prior 24 months) |
| `street-outreach-exits` | 7a.1 | People exiting Street Outreach |
| `people-in-street-outreach` | *(not a HUD measure)* | Unduplicated people with any Street Outreach contact |
| `exits-to-permanent-housing` | 7a.1 + 7b.1 | People exiting Street Outreach or ES/TH/RRH to permanent housing, each person counted once |

There is no project-funding filter: every KPI covers the whole CoC. `hmisguru/westchester` has no `Funder` table, so there's no funded-project subset to scope to.

## Full System Performance Dashboard

Want every HUD measure, not just the KPIs above? **https://hmisguru.github.io/westchester-kpis/spm/** renders all 9 measure widgets from `wcspm.yml` (Measures 1, 2, 3.2, 4, 5.1, 5.2, 7a.1, 7b.1, 7b.2) as a static page — a full Observable rendering of the dashboard, CoC-wide, for the current vs. previous fiscal year. Has its own light/dark toggle in the page (light by default). `people-in-street-outreach` isn't on this page since it isn't a `wcspm.yml` widget — KPI tiles only.

## Embedding

There are three ways to put the KPIs on another website. All of them update automatically when this site rebuilds (first Wednesday of each month). The site's [embedding guide](https://hmisguru.github.io/westchester-kpis/embedding) has copy-and-paste snippets.

### 1. JavaScript module (recommended)

Renders the tiles directly into your page, so they fit your layout and resize on phones.

```html
<div id="westchester-kpis"></div>
<script type="module">
  import {KPIGrid} from "https://hmisguru.github.io/westchester-kpis/kpis.js";
  document.querySelector("#westchester-kpis").append(await KPIGrid());
</script>
```

Common variations:

```js
// Only some KPIs, in this order
await KPIGrid(["people-sheltered", "first-time-homeless"])

// A single tile
import {KPI} from "https://hmisguru.github.io/westchester-kpis/kpis.js";
await KPI("exits-to-permanent-housing")
```

| Export | What it returns |
|---|---|
| `KPIGrid(ids?, options?)` | A responsive grid of tiles (all seven by default), with one source line below it |
| `KPI(id, options?)` | A single tile, with its own source line |
| `data()` | The underlying numbers, for building your own display |

| Option | Applies to | Default | Effect |
|---|---|---|---|
| `theme` | `KPIGrid`, `KPI` | `"light"` | `"dark"` for the dark style, `"auto"` to follow the visitor's system setting |
| `description` | `KPIGrid`, `KPI` | `true` | `false` hides the one-line definition on each tile |
| `footer` | `KPIGrid`, `KPI` | `true` | `false` hides the fiscal year and source line |

The tiles are styled to match [socialservices.westchestercountyny.gov](https://socialservices.westchestercountyny.gov/) (deep forest green, that site's own success/danger colors, "sofia-pro"/"degular" with Google Fonts fallbacks). To adapt them to another site, override these CSS custom properties on `.wkpi`: `--wkpi-font` (body text), `--wkpi-font-display` (the large value number and eyebrow label), `--wkpi-surface`, `--wkpi-border`, `--wkpi-accent` (top stripe), `--wkpi-eyebrow` (measure label), `--wkpi-text`, `--wkpi-text-secondary`, `--wkpi-good`, `--wkpi-bad`, `--wkpi-neutral`.

### 2. Iframe

Works anywhere you can paste HTML, but the iframe needs a fixed height and uses the system font rather than your site's font.

```html
<!-- Full grid -->
<iframe src="https://hmisguru.github.io/westchester-kpis/embed/all"
  title="Westchester CoC system performance KPIs"
  width="100%" height="630" style="border:0"></iframe>

<!-- One KPI -->
<iframe src="https://hmisguru.github.io/westchester-kpis/embed/people-sheltered"
  title="People in shelter or transitional housing"
  width="360" height="340" style="border:0"></iframe>
```

| URL parameter | Pages | Effect |
|---|---|---|
| `theme=dark` or `theme=auto` | all | Dark style, or follow the visitor's system setting |

Single-KPI pages are `embed/<id>`, using the ids in the KPI table above. Suggested heights: about 340px for a single tile at 360px wide; for `embed/all`, about 630px at desktop width, about 790px around 900px wide, and about 1,700px on phones, where the tiles stack. That last one is why the JavaScript module is the better fit for responsive pages.

### 3. Raw JSON

https://hmisguru.github.io/westchester-kpis/data/spm.json has every figure.

## How it works

- `sql/*.sql` are mostly copies of widgets in the System Performance Dashboard (`wcspm.yml` in `hmisguru/westchester`, `main` branch), so published numbers match the dashboard. Regenerate with `scripts/extract_sql.py`; don't hand-edit. `sql/m7_exits_to_ph.sql` is generated from the 7a.1 and 7b.1 copies: each measure's logic is unchanged, and only the final unduplicated count of people exiting either to permanent housing is added. `sql/street_outreach_active.sql` is the one exception — hand-written, not generated, since it has no `wcspm.yml` widget to copy from (see its own header comment).
- `src/data/spm.json.py` is a build-time data loader: it runs those queries in BigQuery and writes a small JSON of CoC-wide aggregates for the KPI tiles. `src/data/spm-dashboard.json.py` runs all 9 `wcspm.yml`-sourced ones and writes every result row, for the full dashboard page. No row-level data or credentials reach the site.
- `.github/workflows/deploy.yml` rebuilds and deploys monthly (first Wednesday of the month), on every push to `main`, and on demand (Actions → Build and deploy KPIs → Run workflow).

## Local development

```sh
npm install
pip install -r requirements.txt
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json
npm run dev      # preview at http://127.0.0.1:3000
npm run build    # static site in dist/
```

The loader's output is cached in `src/.observablehq/cache/`; run `npm run clean` to force a fresh BigQuery pull.
