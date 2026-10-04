---
title: System Performance Dashboard
toc: false
---

<link rel="stylesheet" href="../components/spm-dashboard.css">
<link rel="stylesheet" href="../components/share.css">

```js
import {renderNotes, renderDashboard, renderThemeToggle} from "../components/spm-dashboard.js";
import {renderShareControls} from "../components/share.js";
const spm = FileAttachment("../data/spm-dashboard.json").json();
```

<div class="spmd-header">

# Westchester CoC System Performance Dashboard

<p class="lede">Every HUD System Performance Measure computed for the Westchester County Continuum of Care (NY-604).</p>

```js
const themeToggle = renderThemeToggle();
const shareControls = renderShareControls({
  subject: "Westchester CoC System Performance Dashboard",
  body: "The full HUD System Performance Dashboard for the Westchester County Continuum of Care (NY-604):"
});
const pageControls = document.createElement("div");
pageControls.className = "page-controls";
pageControls.append(themeToggle, shareControls);
display(pageControls);
```

</div>

```js
display(renderNotes(spm));
```

```js
display(renderDashboard(spm));
```

<p class="footer-note">Generated ${spm.generated}.</p>

Looking for just the headline numbers? See the <a href="../">KPI tiles</a>.

<style>
.lede { max-width: 820px; font-size: 18px; }
.footer-note { font-size: 12px; color: #6c6d74; margin-top: 24px; }

/* Theme toggle + share controls, side by side; wraps on narrow screens
   rather than the toggle and share buttons overlapping. */
.page-controls { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
</style>
