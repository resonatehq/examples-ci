#!/usr/bin/env bun
import { parse as parseYaml } from "yaml";
import { readFileSync } from "node:fs";

type Sdk = "ts" | "py" | "rs";

type Entry = {
  repo: string;
  sdk: Sdk;
  kind?: "worker" | "script";
  entry?: string;
  timeout_s?: number;
  healthy_after_s?: number;
  health_regex?: string;
  skip?: boolean;
};

const SDK_DEFAULTS: Record<Sdk, { entry: string; timeout_s: number; healthy_after_s: number }> = {
  ts: { entry: "npm start", timeout_s: 60, healthy_after_s: 15 },
  py: { entry: "python main.py", timeout_s: 60, healthy_after_s: 15 },
  rs: { entry: "cargo run --release", timeout_s: 120, healthy_after_s: 20 },
};

const versions: Record<Sdk, string> = {
  ts: process.env.TS_VERSION ?? "",
  py: process.env.PY_VERSION ?? "",
  rs: process.env.RS_VERSION ?? "",
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
    };
  });

process.stdout.write(JSON.stringify(matrix));
