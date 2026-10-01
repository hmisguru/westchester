---
title: KPI
header: false
footer: false
sidebar: false
toc: false
pager: false
---

```js
import {findKpi, renderKpi} from "../components/kpi.js";
const spm = FileAttachment("../data/spm.json").json();
```

```js
const params = new URLSearchParams(location.search);
const theme = params.get("theme") ?? undefined;
display(renderKpi(spm, findKpi(spm, observable.params.kpi), {theme}));
```

<style>
#observablehq-main, #observablehq-center { margin: 0; padding: 0; max-width: none; }
body { background: transparent; }
</style>
