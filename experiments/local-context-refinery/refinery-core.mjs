import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

export const REFINERY_VERSION = "0.1.0";
export const DEFAULT_MAX_BYTES = 5 * 1024 * 1024;
export const DEFAULT_MAX_EVIDENCE = 40;

const severityRank = { critical: 0, error: 1, blocked: 2, warning: 3, summary: 4, info: 5 };

const secretPatterns = [
  [/\b(Authorization\s*:\s*Bearer)\s+[^\s]+/gi, "$1 [REDACTED]"],
  [/\b(Bearer)\s+[A-Za-z0-9._~+/=-]{12,}/gi, "$1 [REDACTED]"],
  [/\b(sk-[A-Za-z0-9_-]{12,}|xox[baprs]-[A-Za-z0-9-]{12,}|gh[pousr]_[A-Za-z0-9]{12,})\b/g, "[REDACTED_TOKEN]"],
  [/\b(api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|secret)\b(\s*[=:]\s*)[^\s,;]+/gi, "$1$2[REDACTED]"],
  [/([?&](?:token|key|secret|signature)=)[^&\s]+/gi, "$1[REDACTED]"],
];

const patterns = {
  critical: [
    /code object is not signed/i,
    /invalid signature/i,
    /resource envelope is obsolete/i,
    /CSSMERR_/i,
    /notari(?:zation|zed|y).*(?:invalid|rejected)/i,
    /malware|revoked certificate/i,
  ],
  error: [
    /\bfatal error\b/i,
    /(^|\s)error:/i,
    /\bBUILD FAILED\b/i,
    /\bTEST FAILED\b/i,
    /Test Suite .* failed/i,
    /\buncaught exception\b/i,
    /\b(?:ELIFECYCLE|ERR!|panic:)\b/i,
    /"code"\s*:\s*-3260[123]/i,
  ],
  blocked: [
    /permission denied|operation not permitted/i,
    /request timed out|connection timed out|\btimeout\b/i,
    /No space left on device|disk (?:is )?full/i,
    /ECONNREFUSED|ENETUNREACH|network is unreachable/i,
    /requires (?:approval|authorization|permission)/i,
  ],
  warning: [/\bwarning:/i, /\bdeprecated\b/i, /will be removed in/i],
  summary: [
    /\bBUILD SUCCEEDED\b/i,
    /Test Suite .* (?:passed|failed)/i,
    /Executed \d+ tests?/i,
    /\b\d+ (?:tests? )?passed\b/i,
    /status\s*[:=]\s*Accepted/i,
    /notari(?:zation|zed).*Accepted/i,
    /tools\/(?:list|call)/i,
    /JSON-RPC|MCP server/i,
  ],
};

function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function clampInteger(value, fallback, min, max) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? Math.min(max, Math.max(min, parsed)) : fallback;
}

export function redactLine(line) {
  let output = line;
  let redactions = 0;
  for (const [pattern, replacement] of secretPatterns) {
    output = output.replace(pattern, (...args) => {
      redactions += 1;
      return typeof replacement === "string"
        ? replacement.replace(/\$(\d)/g, (_, index) => args[Number(index)] ?? "")
        : replacement;
    });
  }
  return { text: output, redactions };
}

function classify(line) {
  if (/\b0 errors?\b/i.test(line) || /\b0 failed\b/i.test(line)) {
    return patterns.summary.some((pattern) => pattern.test(line)) ? "summary" : null;
  }
  for (const severity of ["critical", "error", "blocked", "warning", "summary"]) {
    if (patterns[severity].some((pattern) => pattern.test(line))) return severity;
  }
  return null;
}

function inferCauses(evidence) {
  const diagnosticEvidence = evidence.filter((item) => ["critical", "error", "blocked"].includes(item.severity));
  const joined = diagnosticEvidence.map((item) => item.text).join("\n");
  const causes = [];
  if (/No space left|disk (?:is )?full/i.test(joined)) causes.push("Insufficient disk headroom");
  if (/permission denied|operation not permitted|requires (?:approval|authorization|permission)/i.test(joined)) causes.push("Permission or authorization boundary");
  if (/code object is not signed|invalid signature|CSSMERR_|notari(?:zation|zed).*(?:invalid|rejected)/i.test(joined)) causes.push("Signing or notarization failure");
  if (/ECONNREFUSED|ENETUNREACH|network is unreachable|timed out|timeout/i.test(joined)) causes.push("Transport or service availability failure");
  if (/fatal error|(^|\s)error:/im.test(joined)) causes.push("Compiler or build diagnostic present");
  if (/Test Suite .* failed|TEST FAILED|\b[1-9]\d* failed\b/i.test(joined)) causes.push("Test failure present");
  return causes.slice(0, 6);
}

export function refineText(text, options = {}) {
  if (typeof text !== "string") throw new TypeError("Log input must be UTF-8 text.");
  const maxBytes = clampInteger(options.maxBytes, DEFAULT_MAX_BYTES, 1_024, 20 * 1024 * 1024);
  const inputBytes = Buffer.byteLength(text, "utf8");
  if (inputBytes > maxBytes) {
    throw new RangeError(`Log is ${inputBytes} bytes; configured fail-closed limit is ${maxBytes} bytes.`);
  }

  const lines = text.split(/\r?\n/);
  const candidates = [];
  const seen = new Set();
  let redactions = 0;

  for (let index = 0; index < lines.length; index += 1) {
    const raw = lines[index];
    const severity = classify(raw);
    if (!severity) continue;
    const redacted = redactLine(raw.trim());
    redactions += redacted.redactions;
    if (!redacted.text) continue;
    const dedupeKey = `${severity}:${redacted.text.replace(/\b\d{2,}\b/g, "#")}`;
    if (seen.has(dedupeKey)) continue;
    seen.add(dedupeKey);
    candidates.push({
      line: index + 1,
      severity,
      text: redacted.text,
      sha256: sha256(redacted.text),
    });
  }

  const maxEvidence = clampInteger(options.maxEvidence, DEFAULT_MAX_EVIDENCE, 1, 100);
  const evidence = [...candidates]
    .sort((a, b) => severityRank[a.severity] - severityRank[b.severity] || a.line - b.line)
    .slice(0, maxEvidence)
    .sort((a, b) => a.line - b.line);

  const hasFailure = candidates.some((item) => item.severity === "critical" || item.severity === "error");
  const hasBlocked = candidates.some((item) => item.severity === "blocked");
  const hasSuccess = candidates.some((item) => item.severity === "summary" && /SUCCEEDED|passed|Accepted/i.test(item.text));
  const status = hasFailure ? "fail" : hasBlocked ? "blocked" : hasSuccess ? "pass" : "unknown";
  const counts = Object.fromEntries(["critical", "error", "blocked", "warning", "summary"].map(
    (severity) => [severity, candidates.filter((item) => item.severity === severity).length],
  ));
  const omittedCount = Math.max(0, candidates.length - evidence.length);
  const omissions = [];
  if (omittedCount > 0) omissions.push(`${omittedCount} lower-priority or duplicate diagnostics omitted by the evidence cap.`);
  if (status === "unknown") omissions.push("No terminal success, failure, or blocker marker was recognized; supervisor must inspect bounded source context.");

  const sourceText = options.sourcePath ? path.resolve(options.sourcePath) : "inline";
  const report = {
    schema_version: "1.0",
    status,
    summary: `Deterministic ${options.kind ?? "auto"} reduction: ${counts.critical} critical, ${counts.error} error, ${counts.blocked} blocked, ${counts.warning} warning, ${counts.summary} summary marker(s).`,
    evidence,
    suspected_causes: inferCauses(evidence),
    omissions,
    confidence: status === "unknown" ? 0.25 : evidence.length > 0 ? 0.9 : 0.5,
    requires_supervisor: true,
    source: {
      kind: options.kind ?? "auto",
      path: sourceText,
      bytes: inputBytes,
      total_lines: lines.length,
      sha256: sha256(text),
    },
    reducer: {
      name: "throttle-deterministic-log-reducer",
      version: REFINERY_VERSION,
      redactions,
      total_candidates: candidates.length,
      evidence_cap: maxEvidence,
      truncated: omittedCount > 0,
    },
  };
  const outputBytes = Buffer.byteLength(JSON.stringify(report), "utf8");
  report.reducer.compression_ratio = outputBytes > 0 ? Number((inputBytes / outputBytes).toFixed(2)) : 0;
  return report;
}

export function configuredRoots(env = process.env) {
  const raw = env.THROTTLE_REFINERY_ROOTS;
  return (raw ? raw.split(path.delimiter) : [process.cwd()])
    .filter(Boolean)
    .map((root) => path.resolve(root));
}

export function resolveAllowedPath(inputPath, roots = configuredRoots()) {
  if (typeof inputPath !== "string" || inputPath.trim() === "") throw new TypeError("A non-empty path is required.");
  const resolved = fs.realpathSync(path.resolve(inputPath));
  const allowed = roots.some((root) => {
    let canonicalRoot;
    try { canonicalRoot = fs.realpathSync(root); } catch { canonicalRoot = path.resolve(root); }
    return resolved === canonicalRoot || resolved.startsWith(`${canonicalRoot}${path.sep}`);
  });
  if (!allowed) throw new Error("Path is outside THROTTLE_REFINERY_ROOTS.");
  const stat = fs.statSync(resolved);
  if (!stat.isFile()) throw new Error("Path must resolve to a regular file.");
  const basename = path.basename(resolved).toLowerCase();
  if (/^(?:\.env(?:\..*)?|id_rsa|id_ed25519)$|credential|secret|token|cookie|keychain|\.p12$|\.pfx$|\.pem$|\.key$/i.test(basename)) {
    throw new Error("Sensitive-looking filenames are never accepted as log inputs.");
  }
  const allowedExtensions = new Set([".log", ".txt", ".json", ".jsonl", ".out", ".err"]);
  if (!allowedExtensions.has(path.extname(basename))) {
    throw new Error("Unsupported input type; expected a log, text, JSON, JSONL, out, or err file.");
  }
  return resolved;
}

export function refineFile(inputPath, options = {}) {
  const resolved = resolveAllowedPath(inputPath, options.roots ?? configuredRoots());
  const maxBytes = clampInteger(options.maxBytes, DEFAULT_MAX_BYTES, 1_024, 20 * 1024 * 1024);
  const stat = fs.statSync(resolved);
  if (stat.size > maxBytes) {
    throw new RangeError(`Log is ${stat.size} bytes; configured fail-closed limit is ${maxBytes} bytes.`);
  }
  const text = fs.readFileSync(resolved, "utf8");
  return refineText(text, { ...options, maxBytes, sourcePath: resolved });
}
