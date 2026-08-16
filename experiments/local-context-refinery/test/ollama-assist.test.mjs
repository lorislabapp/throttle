import assert from "node:assert/strict";
import test from "node:test";
import { assistWithOllama, buildOllamaRequest, localModelConfiguration } from "../ollama-assist.mjs";

const report = {
  status: "unknown",
  summary: "No terminal marker.",
  evidence: [],
  suspected_causes: [],
  omissions: ["No terminal marker."],
};

test("does not contact a runtime when no model is configured", async () => {
  const result = await assistWithOllama(report, { model: "" });
  assert.equal(result.status, "unavailable");
  assert.match(result.reason, /not configured/);
});

test("rejects non-loopback local-model endpoints before network access", async () => {
  const result = await assistWithOllama(report, { model: "qwen-pinned", endpoint: "https://example.com" });
  assert.equal(result.status, "rejected");
  assert.match(result.reason, /loopback-only/);
});

test("reads model configuration without probing the endpoint", () => {
  const config = localModelConfiguration({
    THROTTLE_REFINERY_MODEL: "qwen-pinned",
    THROTTLE_REFINERY_OLLAMA_URL: "http://localhost:11434",
  });
  assert.deepEqual(config, { model: "qwen-pinned", endpoint: "http://localhost:11434" });
});

test("uses bounded non-thinking structured inference", () => {
  const payload = buildOllamaRequest(report, "qwen3.5:4b");
  assert.equal(payload.think, false);
  assert.equal(payload.stream, false);
  assert.equal(payload.options.num_ctx, 4_096);
  assert.equal(payload.options.num_predict, 512);
  assert.equal(payload.format.additionalProperties, false);
  assert.ok(payload.format.required.includes("selected_evidence_sha256"));
  assert.doesNotMatch(payload.messages[1].content, /super-secret/);
});
