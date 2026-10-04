---
title: System Performance Dashboard
toc: false
---

<link rel="stylesheet" href="../components/spm-dashboard.css">

```js
import {renderNotes, renderDashboard, renderThemeToggle} from "../components/spm-dashboard.js";
const spm = FileAttachment("../data/spm-dashboard.json").json();
```

<div class="spmd-header">

# Westchester CoC System Performance Dashboard

<p class="lede">Every HUD System Performance Measure computed for the Westchester County Continuum of Care (NY-604).</p>

```js
const themeToggle = renderThemeToggle();
const pageControls = document.createElement("div");
pageControls.className = "page-controls";
pageControls.append(themeToggle);
display(pageControls);
```

</div>

```js
display(renderDashboard(spm));
```

```js
const notesDetails = document.createElement("details");
notesDetails.className = "spmd-notes-details";
const notesSummary = document.createElement("summary");
notesSummary.textContent = "About this data";
notesDetails.append(notesSummary, renderNotes(spm));
display(notesDetails);
```

<p class="footer-note">Generated ${spm.generated}.</p>

Looking for just the headline numbers? See the <a href="../">KPI tiles</a>.

<style>
.lede { max-width: 820px; font-size: 18px; }
.footer-note { font-size: 12px; color: #6c6d74; margin-top: 24px; }

/* Theme toggle + share controls, side by side; wraps on narrow screens
   rather than the toggle and share buttons overlapping. margin-top (rather
   than on .spmd-theme-toggle itself) keeps the row's own spacing below the
   lede without unevenly offsetting one button against its siblings. */
.page-controls { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; margin-top: 8px; }
</style>
