#!/usr/bin/env bun
import { parse as parseYaml } from "yaml";
import { readFileSync } from "node:fs";

type Sdk = "ts" | "py" | "rs" | "go";

type ProcessEntry = {
  name?: string;
  entry: string;
  ready_regex?: string;
  healthy_after_s?: number;
};

type ClientEntry = {
  entry?: string;
  timeout_s?: number;
  // Blocking-gateway shell driver: spawn `background` async, poll
  // `wait_for.file` for `wait_for.pattern`'s first capture group, export
  // it as $`wait_for.capture`, then run `then.entry` with substitution.
  // Pass = background eventually exits 0 within `timeout_s`.
  driver?: {
    background: { entry: string };
    wait_for: { file: string; pattern: string; capture?: string };
    then: { entry: string };
    timeout_s?: number;
  };
};

type ServiceKind = "redpanda" | "tigerbeetle" | "mock_llm" | "notify_sink";

type Entry = {
  repo: string;
  sdk: Sdk;
  kind?: "worker" | "script";
  entry?: string;
  timeout_s?: number;
  healthy_after_s?: number;
  health_regex?: string;
  requires_server?: boolean;
  server_kind?: "rust" | "legacy_go";
  services?: ServiceKind[];
  setup?: string[];
  processes?: ProcessEntry[];
  client?: ClientEntry;
  skip?: boolean;
};

const SDK_DEFAULTS: Record<Sdk, { entry: string; timeout_s: number; healthy_after_s: number }> = {
  ts: { entry: "npm start", timeout_s: 60, healthy_after_s: 15 },
  py: { entry: "python main.py", timeout_s: 60, healthy_after_s: 15 },
  rs: { entry: "cargo run --release", timeout_s: 120, healthy_after_s: 20 },
  go: { entry: "go run .", timeout_s: 60, healthy_after_s: 15 },
};

const versions: Record<Sdk, string> = {
  ts: process.env.TS_VERSION ?? "",
  py: process.env.PY_VERSION ?? "",
  rs: process.env.RS_VERSION ?? "",
  go: process.env.GO_VERSION ?? "",
};

const filterArg = process.argv[2] ?? "";
const filter = filterArg
  ? new Set(filterArg.split(",").map((s) => s.trim()).filter(Boolean))
  : null;

const yaml = parseYaml(readFileSync("manifests/examples.yaml", "utf8")) as {
  examples: Entry[];
};

const matrix = yaml.examples
  .filter((e) => !e.skip)
  .filter((e) => !filter || filter.has(e.repo))
  .map((e) => {
    const defaults = SDK_DEFAULTS[e.sdk];
    return {
      repo: e.repo,
      sdk: e.sdk,
      sdk_version: versions[e.sdk],
      kind: e.kind ?? "script",
      entry: e.entry ?? defaults.entry,
      timeout_s: e.timeout_s ?? defaults.timeout_s,
      healthy_after_s: e.healthy_after_s ?? defaults.healthy_after_s,
      health_regex: e.health_regex ?? "registered|ready|listening",
      requires_server: e.requires_server ?? false,
      server_kind: e.server_kind ?? "rust",
      services_json: e.services && e.services.length > 0 ? JSON.stringify(e.services) : "",
      multi_config:
        e.processes || e.setup || e.client
          ? JSON.stringify({
              setup: e.setup ?? [],
              processes: e.processes ?? [],
              client: e.client,
            })
          : "",
    };
  });

process.stdout.write(JSON.stringify(matrix));
