# Archive

Code that isn't wired into the live build, kept for possible later reactivation rather than deleted.

## Per-project dropdown for the full SPM dashboard

`spm-dashboard.json.py`, `spm-dashboard.js`, `spm-dashboard.css` are a snapshot of `/spm/`'s data
loader, renderer, and styles as they stood when that page had a single-select Project dropdown —
"All CoC projects" plus one option per "active SPM project" (open, HUD-SPM-covered project type;
121 of 179 `ContinuumProject = 1` projects as of 2026-10-01), each computed independently and in
full at build time (9 widgets x 122 scopes = 1,098 BigQuery queries, capped at
`QUERY_CONCURRENCY = 32`).

Removed per explicit choice (the live page and loader now show CoC-wide figures only — see
`src/data/spm-dashboard.json.py` and `src/components/spm-dashboard.js`/`.css`), but kept here since
it was a real, working, validated feature: confirmed live against BigQuery, and confirmed in CI
that the full 1,098-query build completes in under 2 minutes. `git log` for
`src/data/spm-dashboard.json.py` and `src/components/spm-dashboard.js` has the full history,
including the PRs that built and later removed this (search for "per-project").

### To reactivate

1. Copy `archive/spm-dashboard.json.py` over `src/data/spm-dashboard.json.py`, `archive/spm-dashboard.js`
   over `src/components/spm-dashboard.js`, and merge `archive/spm-dashboard.css`'s `.spmd-controls`,
   `.spmd-select`, `.spmd-select-label` rules back into `src/components/spm-dashboard.css` (the rest of
   that file is unchanged between the two versions, so don't blindly overwrite it).
2. Diff the archived files against the current live ones first -- `sql/*.sql` and `wcspm.yml`
   (`hmisguru/westchester`) may have changed measure logic since this was archived, and the archived
   loader's widget descriptions/columns should be reconciled with whatever's current.
3. `src/spm/index.md` doesn't need changes either way -- it already calls `renderDashboard(spm)` with
   no options, and the per-project version's `renderDashboard` accepts an optional second argument
   (`{projectId}`), so the call stays valid.
