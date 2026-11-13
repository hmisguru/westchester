---
title: Homeless (prototype)
toc: false
---

<link rel="stylesheet" href="../components/homeless.css">

```js
import {homelessInputs, renderAbout, renderDemographics, renderFootnote, renderOverview, renderThemeToggle} from "../components/homeless.js";
const doc = FileAttachment("../data/homeless.json").json();
```

<div class="hl-header">
  <p class="hl-eyebrow">Prototype</p>
  <h1>Homeless</h1>
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
