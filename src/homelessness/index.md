---
title: Homelessness Dashboard (prototype)
toc: false
---

<link rel="stylesheet" href="../components/homelessness.css">

```js
import {homelessInputs, renderAbout, renderDemographics, renderFootnote, renderOverview, renderThemeToggle} from "../components/homelessness.js";
const doc = FileAttachment("../data/homelessness.json").json();
```

<div class="hl-header">
  <p class="hl-eyebrow">Prototype</p>
  <h1>Homelessness Dashboard</h1>
</div>

```js
display(renderThemeToggle());
```

```js
display(renderAbout());
```

```js
const inputs = homelessInputs(doc);
const projectValue = Generators.input(inputs.project);
const householdValue = Generators.input(inputs.household);
const tabValue = Generators.input(inputs.tabs);
display(inputs.controls);
display(inputs.tabs);
```

```js
display(tabValue === "Demographics" ? renderDemographics(doc, [projectValue, householdValue]) : renderOverview(doc, [projectValue, householdValue]));
```

```js
display(renderFootnote(doc));
```
