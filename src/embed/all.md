---
title: KPIs
header: false
footer: false
sidebar: false
toc: false
pager: false
---

```js
import {renderKpiGrid} from "../components/kpi.js";
const spm = FileAttachment("../data/spm.json").json();
```

```js
const params = new URLSearchParams(location.search);
const theme = params.get("theme") ?? undefined;
display(renderKpiGrid(spm, undefined, {theme}));
// The source line sits outside the tiles, on the page background, so a
// dark-themed iframe paints its own dark background rather than relying on
// the host page behind it being dark.
const dark = theme === "dark" || (theme === "auto" && matchMedia("(prefers-color-scheme: dark)").matches);
document.documentElement.classList.toggle("wkpi-dark-page", dark);
```

<style>
#observablehq-main, #observablehq-center { margin: 0; padding: 0; max-width: none; }
body { background: transparent; }
html.wkpi-dark-page, html.wkpi-dark-page body { background: #0f172a; }
</style>
