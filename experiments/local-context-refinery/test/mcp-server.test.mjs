import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import test from "node:test";

test("stdio MCP negotiates, lists read-only tools, and returns structured evidence", async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "throttle-refinery-mcp-"));
  const log = path.join(root, "build.log");
  fs.writeFileSync(log, "warning: old API\n** BUILD SUCCEEDED **\n");
  const server = spawn(process.execPath, [path.resolve("mcp-server.mjs")], {
    cwd: path.resolve("."),
    env: { ...process.env, THROTTLE_REFINERY_ROOTS: root },
    stdio: ["pipe", "pipe", "pipe"],
  });
  t.after(() => {
    server.kill();
    fs.rmSync(root, { recursive: true, force: true });
  });
  const output = readline.createInterface({ input: server.stdout, crlfDelay: Infinity });
  const iterator = output[Symbol.asyncIterator]();
  const call = async (message) => {
    server.stdin.write(`${JSON.stringify(message)}\n`);
    const next = await iterator.next();
    return JSON.parse(next.value);
  };

  const initialized = await call({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-11-25" } });
  assert.equal(initialized.result.protocolVersion, "2025-11-25");
  assert.match(initialized.result.instructions, /Read-only local context refinery/);

  const listed = await call({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
  assert.equal(listed.result.tools.length, 2);
  assert.equal(listed.result.tools[0].annotations.readOnlyHint, true);

  const refined = await call({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "refine_log", arguments: { path: log, kind: "xcode" } } });
  assert.equal(refined.result.structuredContent.status, "pass");
  assert.equal(refined.result.structuredContent.requires_supervisor, true);
  assert.equal(JSON.parse(refined.result.content[0].text).status, "pass");
});
