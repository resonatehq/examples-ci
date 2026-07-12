#!/usr/bin/env bun
// coverage-check: fail when any non-archived example-* repo in resonatehq-examples
// is absent from manifests/examples.yaml. Every repo must have at least a skip: true
// row so the manifest is the explicit record of why it isn't running.
import { parse as parseYaml } from "yaml";
import { readFileSync } from "node:fs";
import { execSync } from "node:child_process";

const yaml = parseYaml(readFileSync("manifests/examples.yaml", "utf8")) as {
  examples: Array<{ repo: string }>;
};

const manifestRepos = new Set(yaml.examples.map((e) => e.repo));

// `gh repo list` is used rather than `gh api /orgs/.../repos?type=public`
// because the REST endpoint with type=public omits repos that are internal-
// visibility or newly created (observed: 108 vs 113 actual repos). --limit 500
// is a generous ceiling; gh handles pagination internally.
let orgRepoNames: string[];
try {
  const raw = execSync(
    "gh repo list resonatehq-examples --limit 500 --json name,isArchived " +
      "--jq '.[] | select(.isArchived == false) | select(.name | startswith(\"example-\")) | .name'",
    { encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }
  );
  orgRepoNames = raw
    .trim()
    .split("\n")
    .filter((r) => r.length > 0);
} catch (err) {
  console.error("coverage-check: gh repo list failed:", err);
  process.exit(1);
}

const missing = orgRepoNames.filter((repo) => !manifestRepos.has(repo));

if (missing.length > 0) {
  console.error(
    `coverage-check: ${missing.length} repo(s) in resonatehq-examples are not in manifests/examples.yaml:`
  );
  for (const repo of missing) {
    console.error(`  missing: ${repo}`);
  }
  console.error(
    "\nAdd each repo with a run entry, build_only: true, or skip: true (with a comment explaining why)."
  );
  process.exit(1);
}

console.log(
  `coverage-check: all ${orgRepoNames.length} non-archived example-* repos are in the manifest.`
);
