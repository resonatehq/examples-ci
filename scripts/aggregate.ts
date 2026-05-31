#!/usr/bin/env bun
import { readFileSync, readdirSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { join } from "node:path";

type Result = {
  repo: string;
  sdk: "ts" | "py" | "rs" | "go";
  sdk_version: string;
  status: string;
  duration_s: number;
  stderr_tail: string;
  job_url?: string;
  // Always present (jq writes the key); empty string when the example didn't
  // spawn a server (Phase 1). When non-empty, server_kind is "rust" or
  // "legacy_go" and server_version is the GH release tag.
  server_version: string;
  server_kind: string;
};

const ARTIFACT_DIR = "artifacts";
const OUT_DIR = "public";
const STATUS_DIR = join(OUT_DIR, "status");

// Fail loud on missing env. Without these, Echo gets a brief with empty
// sdk_version strings and the dashboard shows the wrong "as-of" date.
// Reviewer flagged: ?? "" was masking the upstream resolve step silently
// not emitting the version outputs.
const REQUIRED_ENV = ["RUN_DATE", "RUN_URL", "TS_VERSION", "PY_VERSION", "RS_VERSION", "GO_VERSION"];
for (const name of REQUIRED_ENV) {
  if (!process.env[name]) {
    console.error(`aggregate: required env var ${name} is empty; refusing to emit a malformed summary`);
    process.exit(1);
  }
}

mkdirSync(STATUS_DIR, { recursive: true });

const results: Result[] = [];
if (existsSync(ARTIFACT_DIR)) {
  for (const dir of readdirSync(ARTIFACT_DIR)) {
    const p = join(ARTIFACT_DIR, dir, "result.json");
    if (existsSync(p)) {
      try {
        results.push(JSON.parse(readFileSync(p, "utf8")));
      } catch (err) {
        console.error(`failed to parse ${p}:`, err);
      }
    }
  }
}

results.sort((a, b) => a.repo.localeCompare(b.repo));

const summary = {
  schema_version: "1",
  run_date: process.env.RUN_DATE ?? "",
  run_url: process.env.RUN_URL ?? "",
  versions: {
    ts: process.env.TS_VERSION ?? "",
    py: process.env.PY_VERSION ?? "",
    rs: process.env.RS_VERSION ?? "",
    go: process.env.GO_VERSION ?? "",
  },
  totals: {
    total: results.length,
    passing: results.filter((r) => r.status === "passing").length,
    failing: results.filter((r) => r.status !== "passing").length,
  },
  results,
};

writeFileSync(join(OUT_DIR, "summary.json"), JSON.stringify(summary, null, 2));
writeFileSync("summary.json", JSON.stringify(summary, null, 2));

const COLOR_FOR_STATUS: Record<string, string> = {
  passing: "brightgreen",
  install_failed: "red",
  compile_failed: "red",
  runtime_failed: "red",
  worker_died: "red",
  worker_unhealthy: "red",
  timeout_unhealthy: "red",
};

for (const r of results) {
  const isPass = r.status === "passing";
  writeFileSync(
    join(STATUS_DIR, `${r.repo}.json`),
    JSON.stringify({
      schemaVersion: 1,
      label: "examples-ci",
      message: `${isPass ? "passing" : "failing"} - sdk ${r.sdk_version}`,
      color: COLOR_FOR_STATUS[r.status] ?? "lightgrey",
      cacheSeconds: 3600,
    })
  );
}

const rows = results
  .map((r) => {
    const badge = r.status === "passing" ? "✅" : "❌";
    // Link the status to the per-shard job URL when available so a red row
    // jumps the operator directly to the failing job's logs.
    const statusCell = r.job_url
      ? `<a href="${r.job_url}">${r.status}</a>`
      : r.status;
    const serverCell = r.server_version
      ? `${r.server_kind ?? "rust"} ${r.server_version}`
      : "in memory";
    return `<tr data-sdk="${r.sdk}" data-status="${r.status}"><td class="badge">${badge}</td><td><a href="https://github.com/resonatehq-examples/${r.repo}">${r.repo}</a></td><td><span class="sdk-tag sdk-${r.sdk}">${r.sdk}</span></td><td><code>${r.sdk_version}</code></td><td>${serverCell}</td><td>${statusCell}</td><td class="num">${r.duration_s}s</td></tr>`;
  })
  .join("\n");

const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Resonate examples-ci</title>
<style>
  :root {
    --bg: #080A0E;
    --elevated: #0F1115;
    --subtle: #1A1E26;
    --heading: #E4E7EB;
    --body: #94A3B8;
    --muted: #7E93AE;
    --hairline: rgba(228, 231, 235, 0.08);
    --teal: #1EE3CF;
    --plum: #EC4899;
    --ember: #FBBF24;
    --red: #F87171;
  }
  * { box-sizing: border-box; }
  html, body { background: var(--bg); }
  body {
    font: 14px/1.5 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
    color: var(--body);
    margin: 0;
    padding: 2.5rem 1.5rem 4rem;
  }
  .wrap { max-width: 1040px; margin: 0 auto; }
  .eyebrow {
    color: var(--muted);
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.14em;
    text-transform: uppercase;
    margin: 0 0 0.5rem;
  }
  h1 {
    color: var(--heading);
    font-size: 1.5rem;
    line-height: 1.2;
    margin: 0 0 0.75rem;
    letter-spacing: -0.01em;
    font-weight: 500;
  }
  .sr-only {
    position: absolute;
    width: 1px; height: 1px;
    padding: 0; margin: -1px;
    overflow: hidden;
    clip: rect(0, 0, 0, 0);
    white-space: nowrap;
    border: 0;
  }
  h1 .accent { color: var(--teal); }
  .meta { color: var(--muted); margin: 0 0 2rem; font-size: 13px; }
  .meta strong { color: var(--heading); font-weight: 600; }
  .meta .pass-count { color: var(--heading); font-weight: 600; }
  a { color: var(--teal); text-decoration: none; }
  a:hover { text-decoration: underline; text-decoration-thickness: 1px; text-underline-offset: 3px; }
  a:focus-visible, .filters button:focus-visible {
    outline: 2px solid var(--teal);
    outline-offset: 2px;
    border-radius: 2px;
  }
  code {
    font-family: SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
    background: var(--elevated);
    border: 1px solid var(--hairline);
    color: var(--teal);
    padding: 1px 6px;
    border-radius: 4px;
    font-size: 12px;
  }
  .filters {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 0.4rem;
    margin: 0 0 1.25rem;
    color: var(--muted);
    font-size: 12px;
    text-transform: uppercase;
    letter-spacing: 0.08em;
  }
  .filters .label { margin-right: 0.25rem; }
  .filters button {
    font: inherit;
    text-transform: none;
    letter-spacing: 0;
    font-size: 13px;
    padding: 8px 14px;
    min-height: 36px;
    border: 1px solid var(--hairline);
    background: transparent;
    color: var(--body);
    cursor: pointer;
    border-radius: 6px;
    transition: color 0.15s, border-color 0.15s, background 0.15s;
  }
  .filters button:hover { color: var(--teal); border-color: var(--teal); }
  .filters button.active {
    color: var(--bg);
    background: var(--teal);
    border-color: var(--teal);
    font-weight: 600;
  }
  .table-wrap {
    border: 1px solid var(--hairline);
    border-radius: 8px;
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
    background: var(--elevated);
  }
  table { width: 100%; border-collapse: collapse; }
  th, td { padding: 10px 14px; text-align: left; border-bottom: 1px solid var(--hairline); }
  thead th {
    background: var(--subtle);
    color: var(--muted);
    font-weight: 600;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    border-bottom: 1px solid var(--hairline);
  }
  tbody tr { transition: background 0.12s; }
  tbody tr:last-child td { border-bottom: none; }
  tbody tr:hover { background: rgba(30, 227, 207, 0.04); }
  tbody tr[data-status]:not([data-status="passing"]) {
    background: rgba(236, 72, 153, 0.05);
    box-shadow: inset 3px 0 0 var(--plum);
  }
  tbody tr[data-status]:not([data-status="passing"]) td:nth-child(6) { color: var(--red); }
  td.badge { width: 1.5rem; padding-right: 0; font-size: 13px; }
  td.num { color: var(--muted); font-variant-numeric: tabular-nums; }
  .sdk-tag {
    display: inline-block;
    font-family: SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    font-size: 11px;
    padding: 2px 8px;
    border-radius: 999px;
    border: 1px solid var(--hairline);
    color: var(--body);
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }
  @media (max-width: 480px) {
    body { padding: 1.25rem 1rem 3rem; }
    .filters button { min-height: 44px; padding: 10px 14px; }
    h1 { font-size: 1.25rem; }
  }
</style>
</head>
<body>
<main class="wrap">
<p class="eyebrow">Run ${summary.run_date}</p>
<h1>Resonate <span class="accent">examples-ci</span></h1>
<p class="meta">
  <span class="pass-count">${summary.totals.passing}/${summary.totals.total}</span> passing ·
  SDK ts <code>${summary.versions.ts}</code> · py <code>${summary.versions.py}</code> · rs <code>${summary.versions.rs}</code> · go <code>${summary.versions.go}</code> ·
  <a href="${summary.run_url}">workflow run →</a>
</p>
<div class="filters">
  <span class="label">Filter</span>
  <button class="active" data-filter="all">All</button>
  <button data-filter="ts">TS</button>
  <button data-filter="py">Py</button>
  <button data-filter="rs">Rs</button>
  <button data-filter="go">Go</button>
  <button data-filter="failing">Failing only</button>
</div>
<div class="table-wrap">
<table>
<thead><tr><th aria-label="Status icon"></th><th>Repo</th><th>SDK</th><th>SDK ver</th><th>Server</th><th>Status</th><th>Duration</th></tr></thead>
<tbody>${rows}</tbody>
</table>
</div>
<span id="filter-status" aria-live="polite" class="sr-only"></span>
</main>
<script>
  const status = document.getElementById('filter-status');
  document.querySelectorAll('.filters button').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('.filters button').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      const f = btn.dataset.filter;
      document.querySelectorAll('tbody tr').forEach(tr => {
        if (f === 'all') { tr.style.display = ''; return; }
        if (f === 'failing') { tr.style.display = tr.dataset.status === 'passing' ? 'none' : ''; return; }
        tr.style.display = tr.dataset.sdk === f ? '' : 'none';
      });
      const visible = [...document.querySelectorAll('tbody tr')].filter(r => r.style.display !== 'none').length;
      status.textContent = \`Showing \${visible} example\${visible !== 1 ? 's' : ''}\`;
    });
  });
</script>
</body>
</html>`;

writeFileSync(join(OUT_DIR, "index.html"), html);

console.log(`aggregated ${results.length} results — ${summary.totals.passing} passing, ${summary.totals.failing} failing`);
