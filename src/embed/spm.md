---
title: System Performance Dashboard
header: false
footer: false
sidebar: false
toc: false
pager: false
---

<link rel="stylesheet" href="../components/spm-dashboard.css">

```js
import {renderDashboard, renderNotes} from "../components/spm-dashboard.js";
const spm = FileAttachment("../data/spm-dashboard.json").json();
```

```js
// Sets [data-theme] directly from the URL, not through spm-dashboard.js's own
// applyTheme() -- that persists to localStorage under spmd-theme, a key
// shared with /spm/ and the KPI home page, so an embed's theme choice must
// not leak into the main site's own remembered preference (same reasoning
// /bridge/'s own embed page documents in the sibling hmisguru/baltimore
// repo). Also paints the page's own dark background when dark, rather than
// relying on a transparent body showing through to the host page -- the
// notes box and footer line sit outside any card's own background, same
// issue embed/all.md's own KPI source line has.
const params = new URLSearchParams(location.search);
const theme = params.get("theme");
const dark = theme === "dark" || (theme === "auto" && matchMedia("(prefers-color-scheme: dark)").matches);
if (dark) document.documentElement.dataset.theme = "dark";
document.documentElement.classList.toggle("spmd-dark-page", dark);
```

```js
display(renderDashboard(spm));
```

```js
const notesDetails = document.createElement("details");
notesDetails.className = "spmd-notes-details";
const notesSummary = document.createElement("summary");
notesSummary.textContent = "About this data";
notesDetails.append(notesSummary, renderNotes(spm));
display(notesDetails);
```

<p class="footer-note">Generated ${spm.generated}.</p>

<style>
#observablehq-main, #observablehq-center { margin: 0; padding: 0; max-width: none; }
body { background: transparent; }
html.spmd-dark-page, html.spmd-dark-page body { background: #161616; }
.footer-note { font-size: 12px; color: #6c6d74; margin-top: 24px; }
</style>
