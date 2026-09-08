import assert from "node:assert/strict";
import test from "node:test";
import { refineText } from "../refinery-core.mjs";

test("mixed runner summaries retain failures instead of reporting pass", () => {
  for (const line of [
    "12 passed, 2 failed in 1.0s",
    "2 failed, 12 passed in 1.0s",
    "Executed 12 tests, with 2 failures (0 unexpected)",
    "test result: FAILED. 12 passed; 2 failed; 0 ignored",
    "Tests: 2 failed, 12 passed, 14 total",
  ]) assert.equal(refineText(line).status, "fail", line);
});

test("zero counts cannot mask a critical diagnostic or a different nonzero failure", () => {
  for (const line of [
    "invalid signature; 0 errors",
    "fatal error: compiler crashed; 0 failed tests",
    "12 passed, 0 failed, 2 errors in 1.0s",
  ]) assert.equal(refineText(line).status, "fail", line);
});

test("failure status survives noise, ordering, duplicate successes and evidence caps", () => {
  const failures = ["invalid signature", "12 passed, 2 failed in 1.0s", "** TEST FAILED **"];
  let cases = 0;
  for (const failure of failures) {
    for (const cap of [1, 2, 5, 40]) {
      for (let position = 0; position < 12; position += 1) {
        const lines = Array.from({ length: 12 }, (_, i) => i % 2 ? "** BUILD SUCCEEDED **" : `Compile module ${i}`);
        lines.splice(position, 0, failure);
        const report = refineText(lines.join("\n"), { maxEvidence: cap });
        assert.equal(report.status, "fail", `case ${cases}`);
        assert.ok(report.evidence.some(item => item.text === failure), `missing failure in case ${cases}`);
        cases += 1;
      }
    }
  }
  assert.equal(cases, 144);
});

test("zero tests and prose are not terminal success evidence", () => {
  for (const text of ["0 passed in 1.0s", "The report says 12 passed yesterday.", "no tests ran in 0.01s"]) {
    assert.notEqual(refineText(text).status, "pass", text);
  }
});
