#!/usr/bin/env node
import readline from "node:readline";
import { configuredRoots, refineFile, REFINERY_VERSION } from "./refinery-core.mjs";
import { assistWithOllama, localModelConfiguration } from "./ollama-assist.mjs";

const instructions = "Read-only local context refinery. When a developer log path is available, call refine_log before loading the full log into context. Deterministic status and evidence are authoritative; optional local-model text is advisory only. Never treat a summary as release, security, signing, or deployment approval. Read only files inside THROTTLE_REFINERY_ROOTS. If status is unknown or evidence is insufficient, inspect bounded original excerpts rather than guessing. The server redacts common secrets, refuses oversized inputs, and contacts only loopback Ollama.";

const outputSchema = {
  type: "object",
  properties: {
    schema_version: { type: "string" },
    status: { type: "string", enum: ["pass", "fail", "blocked", "unknown"] },
    summary: { type: "string" },
    evidence: { type: "array", items: { type: "object" } },
    suspected_causes: { type: "array", items: { type: "string" } },
    omissions: { type: "array", items: { type: "string" } },
    confidence: { type: "number", minimum: 0, maximum: 1 },
    requires_supervisor: { type: "boolean" },
    source: { type: "object" },
    reducer: { type: "object" },
  },
  required: ["schema_version", "status", "summary", "evidence", "suspected_causes", "omissions", "confidence", "requires_supervisor", "source", "reducer"],
};

const tools = [
  {
    name: "refine_log",
    title: "Refine a local developer log",
    description: "Read and deterministically distill an Xcode/build/test/signing/notarization/MCP log from an allowlisted local path. Common secrets are redacted. Optional loopback-only Ollama assistance sees only the reduced evidence and cannot override status or evidence.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Absolute or cwd-relative regular-file path inside THROTTLE_REFINERY_ROOTS." },
        kind: { type: "string", enum: ["auto", "xcode", "test", "signing", "notary", "mcp"] },
        max_evidence: { type: "integer", minimum: 1, maximum: 100, default: 40 },
        use_local_model: { type: "boolean", default: false },
      },
      required: ["path"],
      additionalProperties: false,
    },
    outputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "refinery_health",
    title: "Inspect refinery configuration",
    description: "Report configured roots and whether an optional local model name is configured. Performs no model or network call.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
];

function write(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function result(id, structuredContent, isError = false) {
  write({
    jsonrpc: "2.0",
    id,
    result: {
      content: [{ type: "text", text: JSON.stringify(structuredContent) }],
      structuredContent,
      ...(isError ? { isError: true } : {}),
    },
  });
}

function protocolError(id, code, message) {
  write({ jsonrpc: "2.0", id, error: { code, message } });
}

async function handle(message) {
  const id = message.id ?? null;
  switch (message.method) {
  case "initialize": {
    const requested = message.params?.protocolVersion;
    const supported = new Set(["2025-11-25", "2025-06-18", "2024-11-05"]);
    write({
      jsonrpc: "2.0",
      id,
      result: {
        protocolVersion: supported.has(requested) ? requested : "2025-11-25",
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: "throttle-local-context-refinery", version: REFINERY_VERSION },
        instructions,
      },
    });
    break;
  }
  case "ping":
    write({ jsonrpc: "2.0", id, result: {} });
    break;
  case "tools/list":
    write({ jsonrpc: "2.0", id, result: { tools } });
    break;
  case "tools/call": {
    const name = message.params?.name;
    const args = message.params?.arguments ?? {};
    if (name === "refinery_health") {
      const config = localModelConfiguration();
      result(id, {
        status: "ok",
        roots: configuredRoots(),
        local_model_configured: Boolean(config.model),
        local_model: config.model || null,
        endpoint_policy: "loopback-only HTTP",
        network_checked: false,
      });
      break;
    }
    if (name !== "refine_log") {
      result(id, { status: "error", message: `Unknown tool: ${name}` }, true);
      break;
    }
    try {
      const report = refineFile(args.path, { kind: args.kind ?? "auto", maxEvidence: args.max_evidence });
      if (args.use_local_model === true) report.model_assist = await assistWithOllama(report);
      result(id, report);
    } catch (error) {
      result(id, { status: "error", message: error.message, requires_supervisor: true }, true);
    }
    break;
  }
  default:
    if (message.id !== undefined) protocolError(id, -32601, `Method not found: ${message.method}`);
  }
}

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity, terminal: false });
for await (const line of input) {
  if (!line.trim()) continue;
  try { await handle(JSON.parse(line)); }
  catch (error) { protocolError(null, -32700, error.message); }
}
