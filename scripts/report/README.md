# scripts/report — pretty HTML audit reports

Turns a completed leftclaw audit job's markdown report (immutable on bgipfs)
into a styled, self-contained HTML page hosted at
`https://leftclaw.services/result/<job_id>.html`. The IPFS copy stays the
canonical deliverable; this is the human-friendly rendering the jobs page
links to as "Pretty Result".

## Usage

```bash
scripts/report/prettify.sh 400                      # resolve resultURL on-chain, render to out/400.html
scripts/report/prettify.sh 400 https://bafy...com/  # skip the chain read
scripts/report/prettify.sh 400 -o /path/400.html    # custom output path
```

Needs `node` (any modern version) and, for the on-chain resolve, `cast` +
`ALCHEMY_API_KEY` (auto-loaded from `.env.auditor`).

## Publishing

Copy the output into the site repo and push — Vercel deploys it:

```
leftclaw-services/packages/nextjs/public/result/<job_id>.html
```

The shared `leftclaw-services` checkout at `~/clawd/leftclaw-services` is
often another agent's live worktree — publish from a fresh clone, staging
only `packages/nextjs/public/result/`.

## Files

- `prettify.sh` — job id → fetch resultURL (same independent decode as
  `host-auditor/check-job.sh`) → curl markdown → render
- `render.mjs` — markdown → HTML: severity counts from `**Severity**:` lines,
  severity pills in tables and finding headers, TOC from h2s, table wrappers,
  a light sanitizer (report text quotes untrusted repos; strip anything
  executable before hosting on our domain)
- `template.html` — the page shell: leftclaw palette (light + dark via
  `prefers-color-scheme`), severity strip, print CSS. Placeholders:
  `{{TITLE}} {{JOB_ID}} {{JOB_URL}} {{IPFS_URL}} {{GENERATED_DATE}}
  {{SEVERITY_STRIP}} {{TOC}} {{REPORT_BODY}}`
- `vendor/marked.umd.js` — vendored marked v18 so rendering needs no
  `npm install`
- `out/` — generated pages (gitignored)
