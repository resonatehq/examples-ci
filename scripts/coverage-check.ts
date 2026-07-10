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

let orgRepoNames: string[];
try {
  // --paginate follows Link headers; resonatehq-examples has ~100 repos so
  // one request is typically sufficient, but pagination is free.
  const raw = execSync(
    "gh api \"/orgs/resonatehq-examples/repos?per_page=100&type=public\" --paginate " +
      "--jq '.[] | select(.archived == false) | .name'",
    { encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }
  );
  orgRepoNames = raw
    .trim()
    .split("\n")
    .filter((r) => r.startsWith("example-") && r.length > 0);
} catch (err) {
  console.error("coverage-check: gh api call failed:", err);
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
