#!/usr/bin/env python3
"""Build and verify the entire isolated macOS test host with ad hoc signing.

The native pre-run enumeration is the expected inventory. Neither exit zero nor
a green summary alone is evidence: every enumerated case must complete in the
xcresult tree, with only the five named opt-in skips allowed. This Debug host is
not a signed distribution/XPC/CloudKit acceptance artifact.
"""
import argparse
import collections
import hashlib
import json
import os
import pathlib
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import time


ROOT = pathlib.Path(__file__).resolve().parent.parent
ALLOWED_SKIPS = {
    "EmbeddedModelRuntimeTests/testEndToEndDelegationWhenExplicitlyEnabled()": "live MLX delegation",
    "EmbeddedModelRuntimeTests/testEndToEndInferenceWhenExplicitlyEnabled()": "968 MB model and live MLX inference",
    "GlobalRAGServiceTests/testLiveLocalProposalWhenExplicitlyEnabled()": "configured local model",
    "LocalWorkerLiveRouteTests/testConfiguredOllamaServesProjectAssistantWithoutBusinessContext()": "private Ollama acceptance server",
    "NotebookLMImportJobTests/testRecordedLiveExportsReconcileWhenExplicitFixtureIsProvided()": "explicit recorded export fixture",
}
REQUIRED_CASES = {
    "AppTestHostIsolationTests/testActivationKeepsPreviewStateAndCannotConnectInstalledServices()",
    "AppTestHostIsolationTests/testHostedDelegateUsesMigratedMemoryDatabaseWithoutLicense()",
    "AppTestHostIsolationTests/testWorkbenchTestHostHasNoProductionClientOrFolderMonitor()",
    # Keep both test frameworks in the full-host lane.
    "ResearchVaultWorkbenchProjectionTests/projections()",
    "ResearchVaultWorkbenchProjectionTests/savedViews()",
    "ResearchVaultWorkbenchProjectionTests/reasoningSelectors()",
} | set(ALLOWED_SKIPS)
SOURCE_PREFIXES = (
    "Throttle/", "ThrottleTests/", "ThrottleShared/", "ThrottleWidget/",
    "ResearchVaultAgent/", "Packages/ResearchVaultKit/", "Throttle.xcodeproj/",
    "edge-agent/",
)
SOURCE_FILES = {"project.yml", ".github/workflows/ci.yml", "scripts/verify-macos-evidence.py"}


class EvidenceError(ValueError):
    pass


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_json(path):
    # JSON permits duplicate keys in some decoders; evidence must not.
    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise EvidenceError("duplicate_json_key:" + key)
            result[key] = value
        return result
    def reject_constant(value):
        raise EvidenceError("nonfinite_json:" + value)
    with path.open() as stream:
        return json.load(stream, object_pairs_hook=unique_pairs, parse_constant=reject_constant)


def inventory_from_enumeration(report):
    if not isinstance(report, dict) or report.get("errors") != []:
        raise EvidenceError("invalid_or_failed_enumeration")
    plans = report.get("values")
    if not isinstance(plans, list) or len(plans) != 1:
        raise EvidenceError("expected_one_test_plan")
    plan = plans[0]
    if not isinstance(plan, dict) or plan.get("testPlan") != "Throttle" or plan.get("disabledTests") != []:
        raise EvidenceError("wrong_plan_or_disabled_tests")
    tests = plan.get("enabledTests")
    if not isinstance(tests, list) or not tests:
        raise EvidenceError("no_enumerated_tests")
    expected = set()
    for test in tests:
        identifier = test.get("identifier") if isinstance(test, dict) else None
        if not isinstance(identifier, str) or not identifier.startswith("ThrottleTests/"):
            raise EvidenceError("unknown_enumerated_test_target")
        case = identifier.removeprefix("ThrottleTests/")
        if len(case.split("/")) != 2 or not case.endswith("()") or case in expected:
            raise EvidenceError("invalid_or_duplicate_enumerated_case")
        expected.add(case)
    if not REQUIRED_CASES.issubset(expected):
        raise EvidenceError("missing_required_test_host_cases")
    return expected


def validate_reports(summary, tree, expected):
    errors, cases = [], {}
    if not expected:
        errors.append("empty_expected_inventory")
    if not isinstance(summary, dict) or not isinstance(tree, dict):
        return ["invalid_report_root"], cases
    counts = {}
    for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures"):
        value = summary.get(key)
        if type(value) is not int or value < 0:
            errors.append("invalid_summary_count:" + key)
        else:
            counts[key] = value
    if summary.get("result") != "Passed" or summary.get("testFailures") != []:
        errors.append("nonpassing_summary")
    if counts.get("failedTests") != 0 or counts.get("expectedFailures") != 0:
        errors.append("summary_failures")

    def walk(node, bundle=None):
        if not isinstance(node, dict):
            errors.append("invalid_test_node")
            return
        kind = node.get("nodeType")
        if kind not in {"Test Plan", "Unit test bundle", "Test Suite", "Test Case", "Skip Message", "Runtime Warning"}:
            errors.append("unknown_test_node_type:" + str(kind))
        if kind == "Unit test bundle":
            bundle = node.get("name")
            if bundle != "ThrottleTests":
                errors.append("unexpected_test_bundle")
        if kind in {"Test Plan", "Unit test bundle", "Test Suite"}:
            if node.get("result") not in {"Passed", "Skipped"}:
                errors.append("nonpassing_container:" + str(node.get("name")))
        if kind == "Test Case":
            identifier, result = node.get("nodeIdentifier"), node.get("result")
            if bundle != "ThrottleTests" or not isinstance(identifier, str) or not identifier:
                errors.append("invalid_case_identity")
            elif identifier in cases:
                errors.append("duplicate_case:" + identifier)
            else:
                cases[identifier] = result if isinstance(result, str) else "Invalid"
                if result == "Skipped":
                    if identifier not in ALLOWED_SKIPS:
                        errors.append("unexpected_skip:" + identifier)
                elif result != "Passed":
                    errors.append("nonpassing_case:" + identifier)
        children = node.get("children", [])
        if not isinstance(children, list):
            errors.append("invalid_children")
            return
        for child in children:
            walk(child, bundle)

    nodes = tree.get("testNodes")
    if not isinstance(nodes, list) or not nodes:
        errors.append("missing_test_tree")
    else:
        for node in nodes:
            walk(node)
    if not cases:
        errors.append("no_completed_cases")
    errors.extend("missing_case:" + case for case in sorted(expected - set(cases)))
    errors.extend("unexpected_case:" + case for case in sorted(set(cases) - expected))
    observed = collections.Counter(cases.values())
    for key, value in {"totalTestCount": len(cases), "passedTests": observed["Passed"],
                       "skippedTests": observed["Skipped"], "failedTests": 0}.items():
        if counts.get(key) != value:
            errors.append("summary_tree_mismatch:" + key)
    return sorted(set(errors)), cases


def source_snapshot(root=ROOT):
    paths = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=root)
    selected = {path for path in paths.decode().split("\0") if path and
                (path.startswith(SOURCE_PREFIXES) or path in SOURCE_FILES)}
    # XcodeGen's project and schemes are intentionally Git-ignored. They still
    # determine what gets compiled and therefore belong in the source receipt.
    project = root / "Throttle.xcodeproj"
    for path in [project / "project.pbxproj", project / "project.xcworkspace/contents.xcworkspacedata",
                 *project.glob("xcshareddata/xcschemes/*.xcscheme")]:
        if path.exists():
            selected.add(str(path.relative_to(root)))
    if not selected or not any(path.startswith("ThrottleTests/") for path in selected):
        raise EvidenceError("missing_source_inventory")
    # Missing, unreadable or symlinked build inputs cannot get a pass receipt.
    hashes = {}
    for relative in sorted(selected):
        path = root / relative
        if path.is_symlink() or not path.is_file():
            raise EvidenceError("invalid_source_file:" + relative)
        hashes[relative] = sha256(path)
    return hashes


def run_command(command, cwd, log, timeout, commands, output=None):
    started = time.monotonic()
    entry = {"argv": command, "timeout_seconds": timeout}
    commands.append(entry)
    with log.open("ab") as stream:
        stream.write(("\nCOMMAND " + json.dumps(command) + "\n").encode())
        stream.flush()
        target = output.open("wb") if output else stream
        try:
            process = subprocess.Popen(command, cwd=cwd, stdout=target, stderr=stream,
                                       start_new_session=True)
            try:
                entry["exit_code"] = process.wait(timeout=timeout)
            except (subprocess.TimeoutExpired, KeyboardInterrupt):
                # Kill the whole group: a stalled test host must not survive the lane.
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                entry["exit_code"] = 124
                raise EvidenceError("command_timeout_or_interruption")
        finally:
            if output:
                target.close()
            entry["duration_seconds"] = round(time.monotonic() - started, 3)
    if entry["exit_code"]:
        raise EvidenceError("command_failed:" + command[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-parent", type=pathlib.Path, required=True)
    parser.add_argument("--derived-data-path", type=pathlib.Path,
                        help="Reuse a task-owned Xcode cache; reports and source snapshots stay in a new directory")
    args = parser.parse_args()
    args.output_parent.mkdir(parents=True, exist_ok=True)
    output = pathlib.Path(tempfile.mkdtemp(prefix="throttle-macos-", dir=args.output_parent)).resolve()
    evidence = output / "evidence"
    evidence.mkdir()
    commands, errors, sources, expected, cases = [], [], {}, set(), {}
    started, head = time.time(), None
    tools = {}
    result = evidence / "Tests.xcresult"
    log = evidence / "runner.log"
    log.touch()
    try:
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        if platform.system() != "Darwin":
            raise EvidenceError("macos_required")
        for name, command in {"xcode": ["xcodebuild", "-version"], "swift": ["swift", "--version"],
                              "macos": ["sw_vers"], "xcodegen": ["xcodegen", "--version"],
                              "xcresulttool": ["xcrun", "xcresulttool", "version"]}.items():
            destination = evidence / (name + ".txt")
            run_command(command, ROOT, log, 60, commands, destination)
            tools[name] = destination.read_text().strip()
            if not tools[name]:
                raise EvidenceError("missing_tool_version:" + name)
        free = shutil.disk_usage(output).free
        if free < 10 * 1024 ** 3:
            raise EvidenceError("insufficient_disk_before_build:" + str(free))
        # Generate before recording sources: the receipt covers the actual project.
        run_command(["xcodegen", "generate"], ROOT, log, 120, commands)
        sources = source_snapshot()
        (evidence / "sources-before.json").write_text(json.dumps(sources, indent=2) + "\n")
        base = ["xcodebuild", "-project", "Throttle.xcodeproj", "-scheme", "Throttle",
                "-configuration", "Debug", "-destination", "platform=macOS,arch=" + platform.machine(),
                "-derivedDataPath", str(args.derived_data_path.resolve() if args.derived_data_path
                                        else output / "DerivedData"),
                "-disableAutomaticPackageResolution", "-skipPackagePluginValidation", "-skipMacroValidation",
                "-jobs", "2", "-parallel-testing-enabled", "NO",
                "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=",
                "PROVISIONING_PROFILE=", "PROVISIONING_PROFILE_SPECIFIER=", "CODE_SIGN_ENTITLEMENTS=",
                "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=YES", "ENABLE_HARDENED_RUNTIME=NO"]
        run_command(base + ["build-for-testing"], ROOT, log, 2100, commands)
        run_command(base + ["test-without-building", "-enumerate-tests", "-test-enumeration-style", "flat",
                           "-test-enumeration-format", "json", "-test-enumeration-output-path",
                           str(evidence / "enumeration.json")], ROOT, log, 300, commands)
        expected = inventory_from_enumeration(read_json(evidence / "enumeration.json"))
        free = shutil.disk_usage(output).free
        if free < 3 * 1024 ** 3:
            raise EvidenceError("insufficient_disk_before_tests:" + str(free))
        try:
            run_command(base + ["test-without-building", "-test-timeouts-enabled", "YES",
                               "-default-test-execution-time-allowance", "180",
                               "-maximum-test-execution-time-allowance", "300",
                               "-resultBundlePath", str(result)], ROOT, log, 1500, commands)
        except EvidenceError as error:
            errors.append(str(error))
        # Extract even after test failure, preserving the cause and partial evidence.
        for kind in ("summary", "tests"):
            run_command(["xcrun", "xcresulttool", "get", "test-results", kind, "--path", str(result),
                         "--compact"], ROOT, log, 120, commands, evidence / (kind + ".json"))
        report_errors, cases = validate_reports(read_json(evidence / "summary.json"),
                                                read_json(evidence / "tests.json"), expected)
        errors.extend(report_errors)
    except (EvidenceError, OSError, ValueError, subprocess.SubprocessError) as error:
        errors.append(str(error))
    finally:
        try:
            after = source_snapshot()
            (evidence / "sources-after.json").write_text(json.dumps(after, indent=2) + "\n")
            if not sources or sources != after:
                errors.append("sources_changed_or_not_recorded")
        except (EvidenceError, OSError, subprocess.SubprocessError) as error:
            errors.append("source_readback_failed:" + str(error))
        files = {str(path.relative_to(evidence)): sha256(path)
                 for path in sorted(evidence.rglob("*")) if path.is_file()}
        receipt = {
            "schema": 1, "scope": "full-macos-isolated-ad-hoc-debug-tests", "git_head": head,
            "status": "fail" if errors else "pass", "started_at_unix": started,
            "duration_seconds": round(time.time() - started, 3), "tools": tools,
            "architecture": platform.machine(), "python_version": sys.version,
            "sources_sha256": sources, "commands": commands,
            "expected_cases": sorted(expected), "cases": cases, "allowed_skips": ALLOWED_SKIPS,
            "actual_skips": sorted(case for case, status in cases.items() if status == "Skipped"),
            "errors": sorted(set(errors)), "evidence_sha256": files,
            "separate_acceptance_required": ["Developer ID and signed XPC", "CloudKit", "live opt-in tests", "UI and physical companions"],
        }
        (evidence / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(json.dumps({"status": receipt["status"], "cases": len(cases), "errors": receipt["errors"],
                          "evidence": str(evidence)}))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
