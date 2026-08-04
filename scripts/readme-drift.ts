#!/usr/bin/env bun
// readme-drift: fail when a manifest repo's README shows code that no longer
// matches the source file it quotes.
//
// The daily matrix proves the example *runs*. It says nothing about the README,
// which is what most readers actually copy from — so a repo can carry a green
// badge while its README calls an API that doesn't exist. This check closes
// that gap for repos that opt in.
//
// Opting in = committing a sottovoce.json (https://github.com/flossypurse-studios/sottovoce)
// and a directive comment above each fence, so the fence is generated from the
// repo's own source rather than hand-copied. Repos without one are skipped, so
// adoption is per-repo and nothing here needs updating when a repo joins.
//
// Skipped (skip: true) examples ARE checked: whether the example runs in CI and
// whether its README is honest are independent questions.
import { parse as parseYaml } from "yaml";
import { readFileSync, mkdtempSync, rmSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ORG = "resonatehq-examples";
const SOTTOVOCE = join(process.cwd(), "node_modules", ".bin", "sottovoce");
// Concurrency for the opt-in probe. 114 sequential API calls take minutes;
// this keeps the whole discovery pass under ~10s and stays far below the
// 5000/hr authenticated rate limit.
const PROBE_CONCURRENCY = 10;

const yaml = parseYaml(readFileSync("manifests/examples.yaml", "utf8")) as {
  examples: Array<{ repo: string }>;
};
const repos = yaml.examples.map((e) => e.repo);

// `gh api` would be the house style, but one subprocess per repo costs ~100s
// across the manifest. Same endpoint, fetched directly.
const token =
  process.env.GH_TOKEN ||
  process.env.GITHUB_TOKEN ||
  execFileSync("gh", ["auth", "token"], { encoding: "utf8" }).trim();

/** True when the repo has a sottovoce.json at its root on the default branch. */
async function optedIn(repo: string): Promise<boolean> {
  const res = await fetch(
    `https://api.github.com/repos/${ORG}/${repo}/contents/sottovoce.json`,
    {
      method: "HEAD",
      headers: {
        authorization: `Bearer ${token}`,
        accept: "application/vnd.github+json",
        "user-agent": "examples-ci readme-drift",
      },
    }
  );
  if (res.status === 200) return true;
  // 404 is the common case (repo hasn't opted in) — but it is also what a
  // deleted/renamed repo returns, and a rate limit returns 403. Treating any
  // non-200 as "not opted in" is how a check quietly stops checking, so
  // anything other than a clean 404 is a hard failure.
  if (res.status !== 404) {
    console.error(
      `readme-drift: ${ORG}/${repo} probe returned ${res.status} ${res.statusText} — refusing to guess.`
    );
    process.exit(1);
  }
  return false;
}

async function mapLimit<T, R>(
  items: T[],
  limit: number,
  fn: (item: T) => Promise<R>
): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (next < items.length) {
        const i = next++;
        out[i] = await fn(items[i]);
      }
    })
  );
  return out;
}

const flags = await mapLimit(repos, PROBE_CONCURRENCY, optedIn);
const enrolled = repos.filter((_, i) => flags[i]);

if (enrolled.length === 0) {
  console.log(
    `readme-drift: none of the ${repos.length} manifest repos carry a sottovoce.json — nothing to check.`
  );
  process.exit(0);
}

const drifted: string[] = [];
const workdir = mkdtempSync(join(tmpdir(), "readme-drift-"));

try {
  for (const repo of enrolled) {
    const dir = join(workdir, repo);
    execFileSync(
      "git",
      ["clone", "--depth", "1", "--quiet", `https://github.com/${ORG}/${repo}.git`, dir],
      { stdio: ["pipe", "ignore", "inherit"] }
    );
    try {
      // --diff so a failure explains itself in the log: `-` is what the README
      // holds, `+` is what the source now says.
      const out = execFileSync(SOTTOVOCE, ["check", "--diff"], {
        cwd: dir,
        encoding: "utf8",
        stdio: ["pipe", "pipe", "pipe"],
      });
      console.log(`  ok   ${repo}: ${out.trim()}`);
    } catch (err: any) {
      drifted.push(repo);
      const detail = `${err.stdout ?? ""}${err.stderr ?? ""}`.trim();
      console.error(`::group::readme-drift: ${repo}`);
      console.error(detail || err.message);
      console.error("::endgroup::");
    }
  }
} finally {
  rmSync(workdir, { recursive: true, force: true });
}

if (drifted.length > 0) {
  console.error(
    `\n::error::readme-drift: ${drifted.length} of ${enrolled.length} checked repo(s) have README snippets that no longer match their source: ${drifted.join(", ")}`
  );
  console.error(
    "Fix in the example repo: run `npx sottovoce sync` there and commit, or correct the source if the README was right."
  );
  process.exit(1);
}

console.log(
  `readme-drift: all ${enrolled.length} opted-in repo(s) have READMEs in sync with their sources (${repos.length - enrolled.length} not opted in).`
);
