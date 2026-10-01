---
title: System Performance KPIs
---

```js
import {renderKpiGrid} from "./components/kpi.js";
const spm = FileAttachment("./data/spm.json").json();
```

# Westchester CoC System Performance

<p class="lede">Key HUD System Performance Measures for the Westchester County Continuum of Care (NY-604), <b>${spm.fiscal_year.label}</b> compared with ${spm.previous_fiscal_year.label}.</p>

```js
display(renderKpiGrid(spm));
```

<div class="note">

These figures come from the CoC's HMIS and follow HUD's System Performance Measures specifications. They cover the most recent complete federal fiscal year (${spm.fiscal_year.start} to ${spm.fiscal_year.end}) in the HMIS export dated ${spm.export_end}, and are refreshed monthly. Treat them as directionally useful, not audit-exact: they are not the CoC's official HUD submission. The Westchester CoC has no active Street Outreach projects, so the "People exiting Street Outreach" KPI is 0.

</div>

Want to put these on another website? See the [embedding guide](./embedding).

<style>
.lede { max-width: 720px; font-size: 18px; }
</style>
