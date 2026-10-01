// KPI ids, matching the "id" fields written by src/data/spm.json.py. Each gets
// a chrome-free iframe page at /embed/<id>.
const kpiIds = [
  "length-of-time-homeless",
  "returns-to-homelessness",
  "people-sheltered",
  "first-time-homeless",
  "street-outreach-exits",
  "people-in-street-outreach",
  "exits-to-permanent-housing"
];

export default {
  title: "Westchester CoC System Performance KPIs",
  root: "src",
  pages: [
    {name: "Full System Performance Dashboard", path: "/spm/"},
    {name: "Embedding guide", path: "/embedding"}
  ],
  sidebar: false,
  toc: false,
  pager: false,
  search: false,
  theme: "air",
  // Matches socialservices.westchestercountyny.gov's own palette/fonts --
  // see src/components/kpi.js for where these colors and font names came from.
  head: `<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Work+Sans:wght@400;500;700&family=Sora:wght@500;700&display=swap">
<style>:root { --serif: "sofia-pro", "Work Sans", system-ui, sans-serif; --sans-serif: "sofia-pro", "Work Sans", system-ui, sans-serif; --theme-foreground-focus: #02372d; }</style>`,
  // Set explicitly: when unset, Framework adds its own "Built with Observable" footer.
  footer: "Source: Westchester County Continuum of Care (NY-604) HMIS.",
  // Stable, unhashed URLs for embedding: the importable module, the raw JSON,
  // and one iframe page per KPI plus one for the full grid.
  dynamicPaths: [
    "/kpis.js",
    "/data/spm.json",
    "/embed/all",
    ...kpiIds.map((id) => `/embed/${id}`)
  ]
};
