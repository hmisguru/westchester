---
title: Coordinated Entry (prototype)
toc: false
---

<link rel="stylesheet" href="../components/coordinated-entry.css">

```js
import {renderAccessChannelChart, renderEventOutcomesChart, renderFootnote, renderHouseholdTypeChart, renderMonthSlider, renderReachTiles, renderResidentialRateTile, renderThemeToggle, renderTrend} from "../components/coordinated-entry.js";
const doc = FileAttachment("../data/coordinated-entry.json").json();
```

<div class="ce-header">
  <p class="ce-eyebrow">Prototype</p>
  <h1>Coordinated Entry</h1>
</div>

<p class="ce-lede">How Westchester County's Coordinated Entry system is reaching people, month by month over <b>${doc.fiscal_year.label}</b> (${doc.fiscal_year.start} to ${doc.fiscal_year.end}). Unlike this site's other KPIs, these figures compare month to month rather than fiscal year to fiscal year, for more granular detail.</p>

```js
display(renderThemeToggle());
```

```js
const slider = renderMonthSlider(doc, () => {});
const monthIndex = Generators.input(slider.input);
display(slider.wrap);
```

```js
display(renderReachTiles(doc, monthIndex));
```

```js
display(renderTrend(doc, monthIndex));
```

```js
const breakdownRow = document.createElement("div");
breakdownRow.className = "ce-row ce-row-two";
breakdownRow.append(renderHouseholdTypeChart(doc, monthIndex), renderAccessChannelChart(doc, monthIndex));
display(breakdownRow);
```

```js
display(renderResidentialRateTile(doc, monthIndex));
```

```js
display(renderEventOutcomesChart(doc));
```

```js
display(renderFootnote(doc));
```

<style>
h1 { max-width: none; }
</style>
