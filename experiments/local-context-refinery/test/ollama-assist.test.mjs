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

test("falls back to prompt-only contract when the runtime refuses structured output", async () => {
  const http = await import("node:http");
  const hash = "a".repeat(64);
  const bodies = [];
  const server = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (chunk) => { raw += chunk; });
    req.on("end", () => {
      const payload = JSON.parse(raw);
      bodies.push(payload);
      if (payload.format) {
        res.writeHead(501, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: "structured output is unavailable" }));
        return;
      }
      const content = "```json\n" + JSON.stringify({ summary: "One error.", selected_evidence_sha256: [hash], omissions: [], confidence: 0.8 }) + "\n```";
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ message: { role: "assistant", content } }));
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const withEvidence = { ...report, evidence: [{ line: 1, severity: "error", text: "error: x", sha256: hash }] };
    const result = await assistWithOllama(withEvidence, { model: "qwen-mlx", endpoint: `http://127.0.0.1:${server.address().port}` });
    assert.equal(result.status, "ok");
    assert.equal(result.structured_output, "prompt-only");
    assert.deepEqual(result.selected_evidence_sha256, [hash]);
    assert.equal(bodies.length, 2);
    assert.equal(bodies[1].format, undefined);
  } finally {
    server.close();
  }
});
