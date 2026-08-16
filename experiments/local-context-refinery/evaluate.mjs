#!/usr/bin/env node
import fs from "node:fs";
import { performance } from "node:perf_hooks";
import { assistWithOllama, localModelConfiguration } from "./ollama-assist.mjs";
import { refineText } from "./refinery-core.mjs";

const corpus = JSON.parse(fs.readFileSync(new URL("./eval/corpus.json", import.meta.url), "utf8"));
const useModel = process.argv.includes("--model");
const config = localModelConfiguration();
if (useModel && !config.model) {
  console.error("MODEL EVAL BLOCKED: set THROTTLE_REFINERY_MODEL to a pinned local model tag.");
  process.exit(2);
}

let passed = 0;
let criticalRecallHits = 0;
let criticalRecallTotal = 0;
let totalInputBytes = 0;
let totalOutputBytes = 0;
const modelLatencies = [];
const failures = [];

for (const item of corpus.cases) {
  const started = performance.now();
  const report = refineText(item.text, { kind: item.kind, maxEvidence: 40 });
  const serialized = JSON.stringify(report);
  const evidenceText = report.evidence.map((evidence) => evidence.text).join("\n");
  totalInputBytes += Buffer.byteLength(item.text);
  totalOutputBytes += Buffer.byteLength(serialized);
  const reasons = [];
  if (report.status !== item.expected_status) reasons.push(`status ${report.status} != ${item.expected_status}`);
  for (const expected of item.must_keep ?? []) {
    criticalRecallTotal += 1;
    if (evidenceText.includes(expected)) criticalRecallHits += 1;
    else reasons.push(`missing evidence: ${expected}`);
  }
  for (const secret of item.must_redact ?? []) {
    if (serialized.includes(secret)) reasons.push(`secret leaked: ${secret}`);
  }
  if (item.forbid_cause && report.suspected_causes.includes(item.forbid_cause)) {
    reasons.push(`forbidden cause: ${item.forbid_cause}`);
  }

  if (useModel) {
    const modelStarted = performance.now();
    const assist = await assistWithOllama(report, { timeoutMs: 60_000 });
    modelLatencies.push(performance.now() - modelStarted);
    if (assist.status !== "ok") reasons.push(`model assist ${assist.status}: ${assist.reason ?? "unknown"}`);
    if ((assist.invalid_evidence_references_discarded ?? 0) > 0) reasons.push("model referenced evidence not supplied by the reducer");
    if (report.status !== item.expected_status) reasons.push("deterministic status changed during model evaluation");
  }

  const elapsed = performance.now() - started;
  if (reasons.length === 0) passed += 1;
  else failures.push({ id: item.id, reasons });
  console.log(`${reasons.length === 0 ? "PASS" : "FAIL"} ${item.id} ${elapsed.toFixed(1)}ms${reasons.length ? ` — ${reasons.join("; ")}` : ""}`);
}

const recall = criticalRecallTotal === 0 ? 1 : criticalRecallHits / criticalRecallTotal;
const ratio = totalOutputBytes === 0 ? 0 : totalInputBytes / totalOutputBytes;
const modelSorted = [...modelLatencies].sort((a, b) => a - b);
const percentile = (p) => modelSorted.length === 0 ? null : modelSorted[Math.min(modelSorted.length - 1, Math.floor(modelSorted.length * p))];
const summary = {
  corpus_schema: corpus.schema_version,
  cases: corpus.cases.length,
  passed,
  failed: failures.length,
  must_keep_recall: Number(recall.toFixed(4)),
  aggregate_compression_ratio: Number(ratio.toFixed(2)),
  model: useModel ? config.model : null,
  model_latency_ms_p50: percentile(0.5) === null ? null : Number(percentile(0.5).toFixed(1)),
  model_latency_ms_p95: percentile(0.95) === null ? null : Number(percentile(0.95).toFixed(1)),
  failures,
};
console.log(JSON.stringify(summary, null, 2));
if (failures.length > 0 || recall < 1) process.exit(1);
