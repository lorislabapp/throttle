import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { redactLine, refineFile, refineText, resolveAllowedPath } from "../refinery-core.mjs";

test("extracts build evidence, redacts credentials, and fails closed", () => {
  const input = [
    "CompileSwift normal arm64",
    "Authorization: Bearer secret-token-value",
    "/src/App.swift:42: error: cannot find 'thing' in scope api_key=topsecret",
    "** BUILD FAILED **",
  ].join("\n");
  const report = refineText(input, { kind: "xcode" });
  assert.equal(report.status, "fail");
  assert.equal(report.requires_supervisor, true);
  assert.equal(report.evidence.length, 2);
  assert.match(report.evidence[0].text, /api_key=\[REDACTED\]/);
  assert.doesNotMatch(JSON.stringify(report.evidence), /topsecret|secret-token-value/);
  assert.match(report.source.sha256, /^[a-f0-9]{64}$/);
});

test("recognizes a terminal successful test summary", () => {
  const report = refineText("Executed 200 tests, with 0 failures\nTest Suite 'All tests' passed", { kind: "test" });
  assert.equal(report.status, "pass");
  assert.equal(report.evidence.length, 2);
  assert.deepEqual(report.suspected_causes, []);
});

test("returns unknown instead of inventing a result", () => {
  const report = refineText("Compiling module A\nLinking module A", { kind: "xcode" });
  assert.equal(report.status, "unknown");
  assert.ok(report.omissions.some((item) => item.includes("No terminal")));
});

test("rejects oversized input rather than silently truncating", () => {
  assert.throws(() => refineText("x".repeat(2_000), { maxBytes: 1_024 }), /fail-closed limit/);
});

test("allows regular files inside configured roots and rejects traversal", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "throttle-refinery-test-"));
  const inside = path.join(root, "build.log");
  const outside = path.join(os.tmpdir(), `outside-${process.pid}.log`);
  const escapedLink = path.join(root, "escaped.log");
  fs.writeFileSync(inside, "** BUILD SUCCEEDED **\n");
  fs.writeFileSync(outside, "secret\n");
  fs.symlinkSync(outside, escapedLink);
  try {
    assert.equal(resolveAllowedPath(inside, [root]), fs.realpathSync(inside));
    assert.equal(refineFile(inside, { roots: [root] }).status, "pass");
    assert.throws(() => resolveAllowedPath(outside, [root]), /outside THROTTLE_REFINERY_ROOTS/);
    assert.throws(() => resolveAllowedPath(escapedLink, [root]), /outside THROTTLE_REFINERY_ROOTS/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
    fs.rmSync(outside, { force: true });
  }
});

test("redacts common standalone token formats", () => {
  const redacted = redactLine("token=abcdef123456 ghp_abcdefghijklmnopqrstuvwxyz");
  assert.equal(redacted.redactions, 2);
  assert.doesNotMatch(redacted.text, /abcdef123456|ghp_abcdefghijklmnopqrstuvwxyz/);
});

test("rejects sensitive-looking filenames and non-log formats", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "throttle-refinery-sensitive-"));
  const envFile = path.join(root, ".env");
  const sourceFile = path.join(root, "Source.swift");
  fs.writeFileSync(envFile, "API_KEY=secret\n");
  fs.writeFileSync(sourceFile, "fatal error\n");
  try {
    assert.throws(() => resolveAllowedPath(envFile, [root]), /Sensitive-looking filenames/);
    assert.throws(() => resolveAllowedPath(sourceFile, [root]), /Unsupported input type/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
