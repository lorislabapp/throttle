import http from "node:http";

function loopbackEndpoint(raw) {
  const endpoint = new URL(raw ?? "http://127.0.0.1:11434");
  const hosts = new Set(["127.0.0.1", "localhost", "::1", "[::1]"]);
  if (endpoint.protocol !== "http:" || !hosts.has(endpoint.hostname)) {
    throw new Error("Local-model endpoint must be loopback-only HTTP.");
  }
  return endpoint;
}

function boundedStringArray(value) {
  if (!Array.isArray(value)) return [];
  return value.filter((item) => typeof item === "string").slice(0, 6).map((item) => item.slice(0, 500));
}

function validateAssist(value, model, report) {
  if (!value || typeof value !== "object" || typeof value.summary !== "string") {
    throw new Error("Local model returned an invalid JSON contract.");
  }
  const confidence = Number(value.confidence);
  const evidenceHashes = new Set(report.evidence.map((item) => item.sha256));
  const proposedHashes = boundedStringArray(value.selected_evidence_sha256);
  const selectedEvidence = proposedHashes.filter((hash) => evidenceHashes.has(hash));
  const invalidEvidenceReferences = proposedHashes.length - selectedEvidence.length;
  if (report.evidence.length > 0 && selectedEvidence.length === 0) {
    throw new Error("Local model did not select any supplied evidence hash.");
  }
  return {
    status: "ok",
    model,
    summary: value.summary.slice(0, 1_500),
    selected_evidence_sha256: selectedEvidence,
    invalid_evidence_references_discarded: invalidEvidenceReferences,
    omissions: boundedStringArray(value.omissions),
    confidence: Number.isFinite(confidence) ? Math.min(1, Math.max(0, confidence)) : 0,
    authority: "advisory-only",
  };
}

export function localModelConfiguration(env = process.env) {
  return {
    model: env.THROTTLE_REFINERY_MODEL?.trim() ?? "",
    endpoint: env.THROTTLE_REFINERY_OLLAMA_URL?.trim() || "http://127.0.0.1:11434",
  };
}

export function buildOllamaRequest(report, model) {
  const promptPayload = {
    status: report.status,
    deterministic_summary: report.summary,
    evidence: report.evidence,
    deterministic_causes: report.suspected_causes,
    omissions: report.omissions,
  };
  return {
    model,
    stream: false,
    think: false,
    keep_alive: "5m",
    format: {
      type: "object",
      properties: {
        summary: { type: "string", maxLength: 500 },
        omissions: { type: "array", maxItems: 6, items: { type: "string", maxLength: 500 } },
        selected_evidence_sha256: { type: "array", maxItems: 6, items: { type: "string", minLength: 64, maxLength: 64 } },
        confidence: { type: "number", minimum: 0, maximum: 1 },
      },
      required: ["summary", "selected_evidence_sha256", "omissions", "confidence"],
      additionalProperties: false,
    },
    options: { temperature: 0, num_ctx: 4_096, num_predict: 512 },
    messages: [
      {
        role: "system",
        content: "You summarize developer diagnostics using only supplied evidence. Return strict JSON with summary:string, selected_evidence_sha256:string[], omissions:string[], confidence:number. Select only SHA-256 values copied exactly from evidence. Never issue commands, change status, propose a cause, recommend a fix, or invent a missing fact.",
      },
      { role: "user", content: JSON.stringify(promptPayload) },
    ],
  };
}

export async function assistWithOllama(report, options = {}) {
  const config = { ...localModelConfiguration(), ...options };
  if (!config.model) {
    return { status: "unavailable", reason: "THROTTLE_REFINERY_MODEL is not configured.", authority: "advisory-only" };
  }
  let endpoint;
  try { endpoint = loopbackEndpoint(config.endpoint); } catch (error) {
    return { status: "rejected", reason: error.message, authority: "advisory-only" };
  }

  const body = JSON.stringify(buildOllamaRequest(report, config.model));

  const timeoutMs = Math.min(60_000, Math.max(1_000, Number(options.timeoutMs) || 30_000));
  try {
    const response = await new Promise((resolve, reject) => {
      const request = http.request(new URL("/api/chat", endpoint), {
        method: "POST",
        headers: { "content-type": "application/json", "content-length": Buffer.byteLength(body) },
        timeout: timeoutMs,
      }, (incoming) => {
        const chunks = [];
        let bytes = 0;
        incoming.on("data", (chunk) => {
          bytes += chunk.length;
          if (bytes > 1_000_000) {
            incoming.destroy(new Error("Local-model response exceeded 1 MB."));
            return;
          }
          chunks.push(chunk);
        });
        incoming.on("end", () => resolve({ status: incoming.statusCode, body: Buffer.concat(chunks).toString("utf8") }));
        incoming.on("error", reject);
      });
      request.on("timeout", () => request.destroy(new Error("Local-model request timed out.")));
      request.on("error", reject);
      request.end(body);
    });
    if (response.status < 200 || response.status >= 300) throw new Error(`Ollama returned HTTP ${response.status}.`);
    const envelope = JSON.parse(response.body);
    const content = envelope?.message?.content;
    if (typeof content !== "string") throw new Error("Ollama response has no message content.");
    return validateAssist(JSON.parse(content), config.model, report);
  } catch (error) {
    return { status: "unavailable", reason: error.message, model: config.model, authority: "advisory-only" };
  }
}
