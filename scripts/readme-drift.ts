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
// this keeps the whole discovery pass under ~10s. The 5000/hr primary rate
// limit is not the binding constraint at this size — the SECONDARY limit on
// concurrent requests is, and it answers 403 or 429 rather than 404. Those
// are retried below rather than treated as drift.
const PROBE_CONCURRENCY = 10;
const PROBE_TIMEOUT_MS = 15_000;
const PROBE_ATTEMPTS = 4;
// git clone + sottovoce check are bounded so a hung network call fails the
// job in minutes instead of stalling to the Actions 6h default.
const CLONE_TIMEOUT_MS = 120_000;
const CHECK_TIMEOUT_MS = 120_000;

const yaml = parseYaml(readFileSync("manifests/examples.yaml", "utf8")) as {
  examples: Array<{ repo: string }>;
};
const repos = yaml.examples.map((e) => e.repo);

// `gh api` would be the house style, but one subprocess per repo costs ~100s
// across the manifest. Same endpoint, fetched directly.
function resolveToken(): string {
  const fromEnv = process.env.GH_TOKEN || process.env.GITHUB_TOKEN;
  if (fromEnv) return fromEnv;
  // Local runs fall back to the gh CLI. In CI the env var is always set, so
  // reaching here means someone is running the script by hand.
  try {
    return execFileSync("gh", ["auth", "token"], {
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch {
    console.error(
      "readme-drift: no GitHub token. Set GH_TOKEN, or run `gh auth login` and retry."
    );
    process.exit(1);
  }
}

const token = resolveToken();

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Seconds to wait before retrying, honouring GitHub's own backoff headers. */
function retryDelayMs(res: Response, attempt: number): number {
  const retryAfter = Number(res.headers.get("retry-after"));
  if (Number.isFinite(retryAfter) && retryAfter > 0) return retryAfter * 1000;
  // Primary-limit exhaustion: wait until the window resets, capped so a
  // misread header can't park the job for an hour.
  if (res.headers.get("x-ratelimit-remaining") === "0") {
    const reset = Number(res.headers.get("x-ratelimit-reset"));
    if (Number.isFinite(reset)) {
      const wait = reset * 1000 - Date.now();
      if (wait > 0) return Math.min(wait, 60_000);
    }
  }
  return Math.min(1000 * 2 ** attempt, 30_000); // 1s, 2s, 4s
}

/**
 * True when the repo has a sottovoce.json at its root on the default branch.
 *
 * 404 is the common case (repo hasn't opted in). Anything else is ambiguous,
 * so it is retried and only then treated as fatal — a check that silently
 * stops checking is worse than no check, but so is one that reddens the
 * dashboard over a transient 5xx.
 */
async function optedIn(repo: string): Promise<boolean> {
  let last = "";
  for (let attempt = 0; attempt < PROBE_ATTEMPTS; attempt++) {
    let res: Response;
    try {
      res = await fetch(
        `https://api.github.com/repos/${ORG}/${repo}/contents/sottovoce.json`,
        {
          method: "HEAD",
          headers: {
            authorization: `Bearer ${token}`,
            accept: "application/vnd.github+json",
            "user-agent": "examples-ci readme-drift",
          },
          signal: AbortSignal.timeout(PROBE_TIMEOUT_MS),
        }
      );
    } catch (err: any) {
      // Network error or timeout — same treatment as a 5xx.
      last = err?.name === "TimeoutError" ? "request timed out" : String(err);
      if (attempt < PROBE_ATTEMPTS - 1) await sleep(Math.min(1000 * 2 ** attempt, 30_000));
      continue;
    }

    if (res.status === 200) return true;
    if (res.status === 404) return false;

    last = `${res.status} ${res.statusText}`;
    // 403/429 = rate limited (usually the secondary concurrency limit),
    // 5xx = transient. Both are worth another go.
    const retryable = res.status === 403 || res.status === 429 || res.status >= 500;
    if (!retryable || attempt === PROBE_ATTEMPTS - 1) break;
    await sleep(retryDelayMs(res, attempt));
  }

  throw new Error(
    `${ORG}/${repo} probe failed after ${PROBE_ATTEMPTS} attempts (${last}) — refusing to guess whether it is enrolled.`
  );
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

// Probe every repo before failing on any, so one bad response doesn't hide
// the other 113. A rejected probe is reported with its repo name.
const probes = await mapLimit(repos, PROBE_CONCURRENCY, (repo) =>
  optedIn(repo).then(
    (ok) => ({ repo, ok, err: null as string | null }),
    (err) => ({ repo, ok: false, err: err?.message ?? String(err) })
  )
);

const failed = probes.filter((p) => p.err);
if (failed.length > 0) {
  for (const p of failed) console.error(`::error::readme-drift: ${p.err}`);
  console.error(
    `readme-drift: ${failed.length} of ${repos.length} enrollment probes could not be resolved. ` +
      `This is an API problem, not README drift — re-run the job.`
  );
  process.exit(1);
}

const enrolled = probes.filter((p) => p.ok).map((p) => p.repo);

// A repo that goes private (or is renamed) answers 404 exactly like one that
// never enrolled, so the enrolled set can shrink silently. Record it: a drop
// that isn't explained by a deliberate opt-out is worth a human look.
console.log(
  `readme-drift: ${enrolled.length} of ${repos.length} manifest repos are enrolled (carry a sottovoce.json).`
);

if (enrolled.length === 0) {
  console.log("readme-drift: nothing enrolled — nothing to check.");
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
      { stdio: ["pipe", "ignore", "inherit"], timeout: CLONE_TIMEOUT_MS }
    );
    try {
      // --diff so a failure explains itself in the log: `-` is what the README
      // holds, `+` is what the source now says.
      const out = execFileSync(SOTTOVOCE, ["check", "--diff"], {
        cwd: dir,
        encoding: "utf8",
        stdio: ["pipe", "pipe", "pipe"],
        timeout: CHECK_TIMEOUT_MS,
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
    "\nWhat this means: the README shows code that is no longer what the repo contains.\n" +
      "The fix happens in the example repo, not here:\n"
  );
  for (const repo of drifted) {
    console.error(`  https://github.com/${ORG}/${repo}`);
  }
  console.error(
    "\n  git clone the repo, then:\n" +
      "    npx sottovoce sync    # re-render the README from the source files\n" +
      "    git commit -am 'README: re-sync snippets from source'\n" +
      "\n" +
      "  If the README was the one telling the truth, fix the source file instead.\n" +
      "  Background: the README's code fences are generated from the repo's own\n" +
      "  source files, so they cannot drift. See the readme-drift section of this\n" +
      "  repo's README."
  );
  process.exit(1);
}

console.log(
  `readme-drift: all ${enrolled.length} opted-in repo(s) have READMEs in sync with their sources (${repos.length - enrolled.length} not opted in).`
);
