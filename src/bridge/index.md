---
title: Bridge to Housing (prototype)
toc: false
---

<link rel="stylesheet" href="../components/dashboard.css">

```js
import {dashboardInputs, renderAbout, renderFootnote, renderTab, renderThemeToggle} from "../components/dashboard.js";
const dashboard = FileAttachment("../data/dashboard.json").json();
```

<div class="bridge-header">
  <p class="bridge-eyebrow">Prototype</p>
  <!-- Hardcoded to match the sibling dashboard's own page title exactly,
       per explicit request, rather than pulled from dashboard.name --
       dashboard.yml's own "Westchester Performance Dashboard" name is its
       internal DAC identity (shown in Bruin's own admin UI etc.) and stays
       as-is; only this page's own display title changes. -->
  <h1>Bridge to Housing</h1>
</div>

```js
display(renderThemeToggle());
```

```js
display(renderAbout(dashboard));
```

```js
const inputs = dashboardInputs(dashboard);
const householdValue = Generators.input(inputs.household);
const projectValue = Generators.input(inputs.project);
const tabValue = Generators.input(inputs.tabs);
display(inputs.controls);
display(inputs.tabs);
```

```js
display(renderTab(dashboard, tabValue, [householdValue, projectValue]));
```

```js
display(renderFootnote(dashboard));
```

Looking for just the headline numbers? See the <a href="../">KPI tiles</a>.
