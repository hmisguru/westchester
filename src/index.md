---
title: System Performance KPIs
---

<link rel="stylesheet" href="./components/spm-dashboard.css">

```js
import {renderKpiGrid} from "./components/kpi.js";
import {renderThemeToggle} from "./components/spm-dashboard.js";
const spm = FileAttachment("./data/spm.json").json();
```

# Westchester CoC System Performance

<p class="lede">Key System Performance Measures for the Westchester County Continuum of Care (NY-604), <b>${spm.fiscal_year.label}</b> compared with ${spm.previous_fiscal_year.label}.</p>

```js
const themeToggle = renderThemeToggle();
const pageControls = document.createElement("div");
pageControls.className = "page-controls";
pageControls.append(themeToggle);
display(pageControls);
```

```js
// renderKpiGrid's own data-theme is set once at render time (it has no
// [data-theme] cascade like the page chrome does), so this page's shared
// toggle has to push the current theme onto the grid wrapper and every
// tile by hand: once up front (matching whatever renderThemeToggle already
// restored from localStorage, above) and again on each click, after the
// toggle's own listener has flipped document.documentElement.dataset.theme.
const currentTheme = () => (document.documentElement.dataset.theme === "dark" ? "dark" : "light");
const grid = renderKpiGrid(spm, undefined, {theme: currentTheme()});
themeToggle.addEventListener("click", () => {
  const theme = currentTheme();
  grid.dataset.theme = theme;
  grid.querySelectorAll(".wkpi").forEach((tile) => (tile.dataset.theme = theme));
});
display(grid);
```

<details class="note-details">
<summary>About this data</summary>

These figures come from the CoC's HMIS. Seven tiles follow HUD's System Performance Measures specifications; one ("People in Street Outreach") is a dashboard-only addition, not a HUD measure -- its tile is marked "Local Measure 3.3" to flag that distinction while staying consistent with the numbered HUD measures around it. All eight cover the most recent complete federal fiscal year (${spm.fiscal_year.start} to ${spm.fiscal_year.end}) in the HMIS export dated ${spm.export_end}, and are refreshed monthly. Treat them as directionally useful, not audit-exact: they are not the CoC's official HUD submission.

</details>

Want every HUD measure, not just these? See the [full System Performance Dashboard](./spm/) (HUD measures only -- the dashboard-only tile above isn't on that page). Want to put these tiles on another website? See the [embedding guide](./embedding).

<style>
/* Framework's own default h1 max-width (640px, with text-wrap: balance) wraps
   this page's title across two lines -- same workaround already used for
   the full System Performance Dashboard page (see spm-dashboard.css). */
h1 { max-width: none; }
.lede { max-width: 720px; font-size: 18px; }

/* Theme toggle + share controls, side by side; wraps on narrow screens
   rather than the toggle and share buttons overlapping. margin-top (rather
   than on .spmd-theme-toggle itself) keeps the row's own spacing below the
   lede without unevenly offsetting one button against its siblings. */
.page-controls { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; margin-top: 8px; }

/* Collapsed "About this data" note -- lightweight by design (styled summary
   text only, no box/border), since the note had no visual chrome before this
   either; see spm-dashboard.css's html[data-theme="dark"] block (loaded
   above) for the page-chrome dark palette this summary's color matches. */
.note-details { margin-top: 20px; }
.note-details > summary { font-size: 14px; font-weight: 600; color: #02372d; cursor: pointer; list-style: revert; }
.note-details > summary:focus-visible { outline: 2px solid #02372d; outline-offset: 2px; }
.note-details p { margin: 8px 0 0; }
html[data-theme="dark"] .note-details > summary { color: #3dc372; }
html[data-theme="dark"] .note-details > summary:focus-visible { outline-color: #3dc372; }
</style>
