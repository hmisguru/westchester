---
title: Westchester Performance Dashboard (prototype)
toc: false
---

<link rel="stylesheet" href="../components/dashboard.css">

```js
import {dashboardInputs, renderAbout, renderFootnote, renderTab, renderThemeToggle} from "../components/dashboard.js";
const dashboard = FileAttachment("../data/dashboard.json").json();
```

<div class="bridge-header">
  <p class="bridge-eyebrow">Prototype</p>
  <h1>${dashboard.name}</h1>
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
