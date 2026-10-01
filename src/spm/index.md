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
display(renderThemeToggle());
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
</style>
