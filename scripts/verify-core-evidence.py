#!/usr/bin/env python3
"""Run exact production validator sources without the signed GUI/MLX host.

This is a bounded core suite, not the app, SQLCipher, UI or release suite.
Sources/tests are copied byte-for-byte into an isolated SwiftPM package. Their
hashes, complete output and xUnit report are kept with the verification receipt.
"""
import argparse
import hashlib
import json
import pathlib
import os
import re
import signal
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET


ROOT = pathlib.Path(__file__).resolve().parent.parent
FILES = {
    "Sources/Throttle": [
        "Throttle/Services/TestOutcomeDetector.swift",
        "Throttle/Services/TestOutcomeStore.swift",
        "Throttle/Services/ContextFirewall.swift",
        "Throttle/Services/ContentStore.swift",
        "Throttle/Models/PlanModels.swift",
        "Throttle/Models/WorkflowEvidenceReceipt.swift",
        "Throttle/Services/WorkflowResultImporter.swift",
        "Throttle/Services/PlanProjection.swift",
        "Throttle/Services/PlanStore.swift",
        "Throttle/Services/PlanMCPTools.swift",
        "Throttle/Services/PlanMCPRetry.swift",
        "Throttle/Services/PlanMCPTaskRouter.swift",
        "Throttle/Services/PlanMCPAuthority.swift",
        "Throttle/Services/DiagnosticReport.swift",
        "Throttle/Services/DiagnosticArchive.swift",
        "Throttle/Services/TaskWorktreeService.swift",
        "Throttle/Services/TaskIntegrationService.swift",
        "Throttle/Services/TaskIntegrationServiceVerify.swift",
        "Throttle/Services/TaskIntegrationVerifyChild.swift",
    ],
    "Sources/ResearchVaultModel": [
        "Packages/ResearchVaultKit/Sources/ResearchVaultModel/ResearchReceipt.swift",
        "Packages/ResearchVaultKit/Sources/ResearchVaultModel/VaultAuthorization.swift",
    ],
    "Sources/ResearchVaultIPCModel": [
        "Packages/ResearchVaultKit/Sources/ResearchVaultIPCModel/ResearchVaultIPCModel.swift",
        "Packages/ResearchVaultKit/Sources/ResearchVaultIPCModel/ResearchVaultContextEncoding.swift",
        "Packages/ResearchVaultKit/Sources/ResearchVaultIPCModel/ResearchVaultProjectAdmission.swift",
        "Packages/ResearchVaultKit/Sources/ResearchVaultIPCModel/ResearchVaultReasoningDTO.swift",
        "Packages/ResearchVaultKit/Sources/ResearchVaultIPCModel/ResearchVaultReceiptDTO.swift",
        "Packages/ResearchVaultKit/Sources/ResearchVaultIPCModel/ResearchVaultReceiptProvenance.swift",
    ],
    "Sources/ResearchVaultIngestion": [
        "Packages/ResearchVaultKit/Sources/ResearchVaultIngestion/RetrievalBenchmark.swift",
        "Packages/ResearchVaultKit/Sources/ResearchVaultIngestion/RetrievalQualityGate.swift",
    ],
    "Tests/ThrottleTests": ["ThrottleTests/ServiceTests/TestOutcomeDetectorTests.swift",
                            "ThrottleTests/ServiceTests/TestOutcomeStoreTests.swift",
                            "ThrottleTests/ServiceTests/ContextPacketEvidenceTests.swift",
                            "ThrottleTests/ServiceTests/PlanStoreTests.swift",
                            "ThrottleTests/ServiceTests/WorkflowFoundationTests.swift",
                            "ThrottleTests/ServiceTests/PlanMCPRetryTests.swift",
                            "ThrottleTests/ServiceTests/PlanMCPTaskRouterTests.swift",
                            "ThrottleTests/ServiceTests/PlanMCPAuthorityTests.swift",
                            "ThrottleTests/ServiceTests/DiagnosticReportTests.swift",
                            "ThrottleTests/ServiceTests/DiagnosticArchiveTests.swift",
                            "ThrottleTests/ServiceTests/WorkflowEvidenceReceiptTests.swift",
                            "ThrottleTests/ServiceTests/WorkflowResultImporterTests.swift",
                            "ThrottleTests/ServiceTests/TaskIntegrationServiceTests.swift",
                            "ThrottleTests/ServiceTests/TaskIntegrationRefusalTests.swift",
                            "ThrottleTests/ServiceTests/TaskIntegrationOutputTests.swift",
                            "ThrottleTests/ServiceTests/TaskIntegrationHardeningTests.swift"],
    "Tests/ResearchVaultIngestionTests": [
        "Packages/ResearchVaultKit/Tests/ResearchVaultIngestionTests/RetrievalBenchmarkTests.swift",
        "Packages/ResearchVaultKit/Tests/ResearchVaultIngestionTests/RetrievalQualityGateTests.swift",
    ],
}
MANIFEST = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ThrottleCoreEvidence", platforms: [.macOS(.v14)], targets: [
    .target(name: "Throttle"),
    .target(name: "ResearchVaultModel"),
    .target(name: "ResearchVaultIPCModel", dependencies: ["ResearchVaultModel"]),
    .target(name: "ResearchVaultIngestion", dependencies: ["ResearchVaultIPCModel"]),
    .testTarget(name: "ThrottleTests", dependencies: ["Throttle"]),
    .testTarget(name: "ResearchVaultIngestionTests", dependencies: ["ResearchVaultIngestion"]),
])
'''


def validate_reports(paths, expected):
    """Require completed distinct cases in every expected suite, not just exit 0."""
    errors, identities = [], set()
    completed = {}
    for path in paths:
        try:
            tree = ET.parse(path)
            if tree.getroot().tag not in ("testsuites", "testsuite"):
                raise ValueError("unexpected report root")
            for suite in tree.iter("testsuite"):
                if any(int(suite.get(key, "0")) != 0 for key in ("errors", "failures")):
                    errors.append("suite_failure")
            for case in tree.iter("testcase"):
                key = (case.get("classname", "").split(".")[-1], case.get("name", ""))
                if key in identities or not all(key):
                    errors.append("duplicate_or_unnamed_case")
                identities.add(key)
                if case.find("failure") is not None or case.find("error") is not None:
                    errors.append("test_failure")
                elif case.find("skipped") is None:
                    completed.setdefault(key[0], set()).add(key[1].removesuffix("()"))
        except (OSError, ET.ParseError, ValueError):
            errors.append("missing_or_invalid_final_report")
    for suite, methods in expected.items():
        if not set(methods).issubset(completed.get(suite, set())):
            errors.append("missing_completed_cases:" + suite)
    if not identities:
        errors.append("no_completed_testcases")
    return sorted(set(errors)), len(identities)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-parent", type=pathlib.Path)
    parser.add_argument("--scratch-path", type=pathlib.Path,
                        help="Reuse a task-owned Swift build cache; evidence stays in a new directory")
    args = parser.parse_args()
    if args.output_parent:
        args.output_parent.mkdir(parents=True, exist_ok=True)
    output = pathlib.Path(tempfile.mkdtemp(prefix="throttle-core-evidence-", dir=args.output_parent))
    package = output / "package"
    hashes = {}
    expected = {}
    for destination, paths in FILES.items():
        folder = package / destination
        folder.mkdir(parents=True, exist_ok=True)
        for relative in paths:
            data = (ROOT / relative).read_bytes()
            (folder / pathlib.Path(relative).name).write_bytes(data)
            hashes[relative] = hashlib.sha256(data).hexdigest()
            if destination.startswith("Tests/"):
                methods = re.findall(r"(?:@Test\b[\s\S]*?\bfunc\s+|\bfunc\s+(?=test[_A-Z]))(\w+)\s*\(", data.decode())
                if not methods:
                    raise ValueError("No test cases discovered in " + relative)
                expected[pathlib.Path(relative).stem] = methods
    (package / "Package.swift").write_text(MANIFEST)
    base = ["swift", "test", "--package-path", str(package), "--build-system", "native", "--jobs", "2"]
    if args.scratch_path:
        base += ["--scratch-path", str(args.scratch_path.resolve())]
    commands = [base + ["--parallel", "--num-workers", "2", "--disable-swift-testing",
                        "--xunit-output", str(output / "xctest.xml")],
                base + ["--skip-build", "--disable-xctest", "--xunit-output", str(output / "swift-testing.xml")]]
    started = time.time()
    codes = []
    errors = []
    with (output / "output.log").open("wb") as log:
        for command in commands:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                codes.append(process.wait(timeout=900))
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                codes.append(124)
                errors.append("command_timeout")
                break
    reports = sorted(output.glob("*.xml"))
    report_errors, case_count = validate_reports(reports, expected)
    errors.extend(report_errors)
    if any(codes):
        errors.append("command_failed")
    if any(hashlib.sha256((ROOT / path).read_bytes()).hexdigest() != sha for path, sha in hashes.items()):
        errors.append("sources_changed_during_run")
    receipt = {"schema": 1, "scope": "core-validator-subset", "status": "pass" if not errors else "fail",
               "started_at_unix": started, "duration_seconds": round(time.time() - started, 3),
               "commands": commands, "exit_codes": codes, "reported_cases": case_count,
               "expected_cases": expected,
               "sources_sha256": hashes, "errors": errors,
               "manifest_sha256": hashlib.sha256(MANIFEST.encode()).hexdigest(),
               "runner_sha256": hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
               "log_sha256": hashlib.sha256((output / "output.log").read_bytes()).hexdigest(),
               "results_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in reports}}
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({"status": receipt["status"], "cases": case_count, "errors": errors,
                      "evidence": str(output)}))
    if errors:
        print((output / "output.log").read_text(errors="replace")[-6000:])
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
