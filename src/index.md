---
title: System Performance KPIs
---

```js
import {renderKpiGrid} from "./components/kpi.js";
const spm = FileAttachment("./data/spm.json").json();
```

# Westchester CoC System Performance

<p class="lede">Key System Performance Measures for the Westchester County Continuum of Care (NY-604), <b>${spm.fiscal_year.label}</b> compared with ${spm.previous_fiscal_year.label}.</p>

```js
display(renderKpiGrid(spm));
```

<div class="note">

These figures come from the CoC's HMIS. Six tiles follow HUD's System Performance Measures specifications; one ("People in Street Outreach") is a dashboard-only addition, not a HUD measure -- its tile is marked "Dashboard metric" rather than a HUD measure number. All seven cover the most recent complete federal fiscal year (${spm.fiscal_year.start} to ${spm.fiscal_year.end}) in the HMIS export dated ${spm.export_end}, and are refreshed monthly. Treat them as directionally useful, not audit-exact: they are not the CoC's official HUD submission.

</div>

Want every HUD measure, not just these? See the [full System Performance Dashboard](./spm/) (HUD measures only -- the dashboard-only tile above isn't on that page). Want to put these tiles on another website? See the [embedding guide](./embedding).

<style>
.lede { max-width: 720px; font-size: 18px; }
</style>
