// Exported module for embedding KPIs directly in another site's page:
//
//   <div id="kpis"></div>
//   <script type="module">
//     import {KPIGrid} from "https://hmisguru.github.io/westchester/kpis.js";
//     document.querySelector("#kpis").append(await KPIGrid());
//   </script>
//
// Published at a stable URL via dynamicPaths in observablehq.config.js.

import {FileAttachment} from "observablehq:stdlib";
import {findKpi, renderKpi, renderKpiGrid} from "./components/kpi.js";

const spm = FileAttachment("./data/spm.json").json();

/** The KPI document (fiscal year, source, and every KPI's values). */
export async function data() {
  return await spm;
}

/** One KPI tile, e.g. await KPI("exits-to-permanent-housing"). */
export async function KPI(id, options) {
  const d = await spm;
  return renderKpi(d, findKpi(d, id), options);
}

/** A responsive grid of KPI tiles; all of them when ids is omitted. */
export async function KPIGrid(ids, options) {
  return renderKpiGrid(await spm, ids, options);
}
