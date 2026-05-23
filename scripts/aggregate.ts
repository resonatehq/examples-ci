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
  // Empty when the example didn't spawn a server (Phase 1). When set,
  // server_kind is "rust" or "legacy_go" and server_version is the GH release tag.
  server_version?: string;
  server_kind?: string;
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
      : "—";
    return `<tr data-sdk="${r.sdk}" data-status="${r.status}"><td>${badge}</td><td><a href="https://github.com/resonatehq-examples/${r.repo}">${r.repo}</a></td><td>${r.sdk}</td><td>${r.sdk_version}</td><td>${serverCell}</td><td>${statusCell}</td><td>${r.duration_s}s</td></tr>`;
  })
  .join("\n");

const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Resonate examples-ci</title>
<style>
  body { font: 14px/1.5 system-ui, sans-serif; margin: 2rem; max-width: 980px; }
  table { width: 100%; border-collapse: collapse; }
  th, td { padding: 6px 10px; text-align: left; border-bottom: 1px solid #eee; }
  th { background: #fafafa; font-weight: 600; }
  .meta { color: #666; margin: 1rem 0 2rem; }
  .filters { margin-bottom: 1rem; }
  .filters button { margin-right: 6px; padding: 4px 10px; border: 1px solid #ccc; background: #fff; cursor: pointer; border-radius: 4px; }
  .filters button.active { background: #eef; }
  code { background: #f6f6f6; padding: 1px 4px; border-radius: 3px; }
</style>
</head>
<body>
<h1>Resonate examples-ci</h1>
<p class="meta">
  Run date: <strong>${summary.run_date}</strong> ·
  ${summary.totals.passing}/${summary.totals.total} passing ·
  SDK: ts <code>${summary.versions.ts}</code>, py <code>${summary.versions.py}</code>, rs <code>${summary.versions.rs}</code>, go <code>${summary.versions.go}</code> ·
  <a href="${summary.run_url}">workflow run</a>
</p>
<div class="filters">
  Filter:
  <button class="active" data-filter="all">All</button>
  <button data-filter="ts">TS</button>
  <button data-filter="py">Py</button>
  <button data-filter="rs">Rs</button>
  <button data-filter="go">Go</button>
  <button data-filter="failing">Failing only</button>
</div>
<table>
<thead><tr><th></th><th>Repo</th><th>SDK</th><th>SDK ver</th><th>Server</th><th>Status</th><th>Duration</th></tr></thead>
<tbody>${rows}</tbody>
</table>
<script>
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
    });
  });
</script>
</body>
</html>`;

writeFileSync(join(OUT_DIR, "index.html"), html);

console.log(`aggregated ${results.length} results — ${summary.totals.passing} passing, ${summary.totals.failing} failing`);
