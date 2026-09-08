#!/usr/bin/env python3
"""Run every Debug or Release ResearchVaultKit package test with native evidence.

Both XCTest and Swift Testing must report every discovered function without a
skip. Swift Testing XML aggregates parameterized functions, so its native event
stream must additionally complete every argument ID enumerated by the runtime.
Swift's lazy --list-tests discovery currently omits argument IDs: argument
completeness is relative to runtime metadata, not an independent denominator.
If discovery does provide argument IDs, the two inventories must agree exactly.
Release additionally exercises transaction/migration crash rollback and the
direct CLI refusal using the same build products. Neither configuration qualifies
a signed XPC service, real Keychain, live corpus or the full verify.sh workflow.
"""
import argparse
import hashlib
import importlib.util
import json
import math
import os
import pathlib
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET


ROOT = pathlib.Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "Packages/ResearchVaultKit"
spec = importlib.util.spec_from_file_location("vault_evidence_common", ROOT / "scripts/verify-macos-evidence.py")
common = importlib.util.module_from_spec(spec)
spec.loader.exec_module(common)
EvidenceError, sha256, read_json, run_command = common.EvidenceError, common.sha256, common.read_json, common.run_command
REQUIRED_CASES = {
    "ResearchVaultIngestionTests.ResearchDocumentTextExtractorTests/scannedPDFIsRecoveredByOCR()",
    "ResearchVaultXPCTests.ResearchVaultXPCTests/serviceLifetimeIsCancellable()",
    "ResearchVaultXPCTests.ResearchVaultXPCTests/cheatCodeClientContractIsQueryOnly()",
    "ResearchVaultXPCTests.ResearchVaultXPCTests/ownerServiceDispatch()",
    "ResearchVaultXPCTests.ResearchVaultXPCTests/ownerServiceRejectsMalformedBytes()",
    "ResearchVaultXPCTests.ResearchVaultXPCTests/ownerReasoningDispatch()",
}
CASE_PATTERN = re.compile(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*/[A-Za-z_]\w*(?:\([^\s/]*\))?")
RELEASE_DISABLED = b"research-vault-mcp: direct Release mode disabled\n"
INITIALIZE_REQUEST = b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}\n'
SANDBOX_EXEC = pathlib.Path("/usr/bin/sandbox-exec")
CLI_SANDBOX_PROFILE = """(version 1)
(allow default)
(deny network*)
(deny mach-lookup)
(deny process-fork)
(deny file-write*)
(allow file-write* (subpath (param "FIXTURE")))
(deny file-read* (regex #"(^|/)Keychains(/|$)"))
"""


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def package_flags(scratch, configuration):
    require(configuration in {"debug", "release"}, "unknown_build_configuration")
    # Release does not enable testability by default, so every `@testable import`
    # in the test targets fails to compile there (ModuleNotTestable). Both
    # configurations get the same flag: the matrix must differ only by `-c`.
    return ["--package-path", str(PACKAGE), "--scratch-path", str(scratch), "--build-system", "native",
            "-c", configuration, "--jobs", "2", "-Xswiftc", "-enable-testing"]


def validate_crash_recovery(records):
    expected = [
        {"status": "prepared-write"},
        {"status": "expected-crash", "scenario": "crash-write", "exitCode": 86},
        {"status": "pass", "scenario": "write", "rows": 1},
        {"status": "prepared-migration"},
        {"status": "expected-crash", "scenario": "crash-migration", "exitCode": 86},
        {"status": "pass", "scenario": "migration", "schemaVersion": 0},
    ]
    # Exact type-aware comparison: JSON true must not stand in for the row count.
    require(json.dumps(records, sort_keys=True) == json.dumps(expected, sort_keys=True), "incomplete_or_failed_crash_recovery")
    return records


def validate_cli_refusal(exit_code, stdout, stderr):
    require(type(exit_code) is int and exit_code == 1 and stdout == b"" and stderr == RELEASE_DISABLED,
            "release_cli_did_not_explicitly_refuse")


def sandbox_cli_command(command, fixture):
    require(platform.system() == "Darwin" and SANDBOX_EXEC.is_file() and os.access(SANDBOX_EXEC, os.X_OK),
            "release_cli_sandbox_unavailable")
    return [str(SANDBOX_EXEC), "-D", "FIXTURE=" + str(fixture.resolve(strict=True)), "-p", CLI_SANDBOX_PROFILE, *command]


def run_cli_refusal(binary, fixture, evidence, label, commands, *, ephemeral=False):
    fixture.mkdir()
    inbox = fixture / "inbox"
    inbox.mkdir()
    # Both invocations are syntactically complete; a generic usage/startup error
    # cannot be mistaken for the Release-only denial. No corpus path is passed.
    command = [str(binary), "--database", str(fixture / "vault.ccsql"), "--inbox", str(inbox),
               "--project", "throttle", "--maximum-sensitivity", "internal"]
    if ephemeral:
        command.append("--ephemeral-testing-key")
    # This boundary remains effective if a candidate accidentally enables the
    # direct owner or moves the Release guard after its Keychain initialization.
    # Keep HOME and the candidate's arguments unchanged; a generic sandbox or
    # startup error is still a failure, never evidence of the Release denial.
    command = sandbox_cli_command(command, fixture)
    entry = {"argv": command, "timeout_seconds": 30, "expected_exit_code": 1,
             "stdin_sha256": hashlib.sha256(INITIALIZE_REQUEST).hexdigest(),
             "sandbox_profile_sha256": hashlib.sha256(CLI_SANDBOX_PROFILE.encode()).hexdigest()}
    commands.append(entry)
    started = time.monotonic()
    stdout_path, stderr_path = evidence / (label + ".stdout"), evidence / (label + ".stderr")
    # Pipes keep the child from needing a write exception for evidence files
    # outside its fixture. Only this parent writes the captured diagnostics.
    process = subprocess.Popen(command, cwd=fixture, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        stdout, stderr = process.communicate(INITIALIZE_REQUEST, timeout=30)
        entry["exit_code"] = process.returncode
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate()
        stdout_path.write_bytes(stdout)
        stderr_path.write_bytes(stderr)
        entry["exit_code"] = 124
        raise EvidenceError("release_cli_timeout_or_interruption")
    finally:
        entry["duration_seconds"] = round(time.monotonic() - started, 3)
    stdout_path.write_bytes(stdout)
    stderr_path.write_bytes(stderr)
    validate_cli_refusal(entry["exit_code"], stdout, stderr)
    require(list(fixture.iterdir()) == [inbox] and not list(inbox.iterdir()), "release_cli_created_local_state")
    return {"scenario": label, "status": "pass", "exit_code": entry["exit_code"], "diagnostic": RELEASE_DISABLED.decode().strip(),
            "sandbox_profile_sha256": entry["sandbox_profile_sha256"]}


def release_products(bin_path):
    hashes = {}
    for name in ("research-vault-crash-probe", "research-vault-mcp"):
        path = bin_path / name
        require(path.is_file() and not path.is_symlink() and os.access(path, os.X_OK), "missing_release_product:" + name)
        with path.open("rb") as stream:
            require(stream.read(4) in {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"},
                    "release_product_is_not_macho:" + name)
        hashes[name] = sha256(path)
    return hashes


def inventory(text):
    cases = text.splitlines()
    require(bool(cases) and all(CASE_PATTERN.fullmatch(case) for case in cases), "invalid_or_empty_inventory")
    require(len(cases) == len(set(cases)), "duplicate_inventory_case")
    return set(cases)


def validate_xml(data, expected):
    require(bool(expected), "empty_expected_inventory")
    require(b"<!DOCTYPE" not in data.upper() and b"<!ENTITY" not in data.upper(), "xml_entities_forbidden")
    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        raise EvidenceError("invalid_xml") from error
    # These are the two native SwiftPM xUnit shapes, not arbitrary JUnit input.
    require(root.tag == "testsuites" and not root.attrib and len(root) == 1, "unknown_xml_root")
    require(all(not (element.text or "").strip() and not (element.tail or "").strip() for element in root.iter()),
            "unknown_xml_text")
    suite = root[0]
    require(suite.tag == "testsuite" and suite.get("name") == "TestResults", "unknown_xml_suite")
    require(set(suite.attrib) <= {"name", "errors", "tests", "failures", "skipped", "time"}, "unknown_xml_suite_attribute")
    for field in ("errors", "failures"):
        require(suite.get(field) == "0", "xml_" + field)
    require(suite.get("skipped", "0") == "0", "xml_skips")
    try:
        duration = float(suite.get("time", ""))
    except ValueError as error:
        raise EvidenceError("invalid_xml_suite_duration") from error
    require(math.isfinite(duration) and duration >= 0, "invalid_xml_suite_duration")
    observed = set()
    for case in suite:
        require(case.tag == "testcase" and len(case) == 0, "failed_skipped_or_unknown_xml_case")
        require(set(case.attrib) == {"classname", "name", "time"}, "unknown_xml_case_attribute")
        identifier = case.get("classname", "") + "/" + case.get("name", "")
        require(CASE_PATTERN.fullmatch(identifier), "invalid_xml_case_identity")
        require(identifier not in observed, "duplicate_xml_case:" + identifier)
        try:
            duration = float(case.get("time", ""))
        except ValueError as error:
            raise EvidenceError("invalid_xml_duration") from error
        require(math.isfinite(duration) and duration >= 0, "invalid_xml_duration")
        observed.add(identifier)
    require(suite.get("tests") == str(len(observed)), "xml_summary_case_mismatch")
    require(observed == expected, "xml_inventory_mismatch:missing=" + repr(sorted(expected - observed)) +
            ";unexpected=" + repr(sorted(observed - expected)))
    return sorted(observed)


def read_records(path):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "duplicate_json_key:" + key)
            result[key] = value
        return result

    def invalid_constant(value):
        raise EvidenceError("nonfinite_json:" + value)

    records = []
    for line in path.read_text().splitlines():
        require(bool(line), "blank_event_record")
        try:
            records.append(json.loads(line, object_pairs_hook=pairs, parse_constant=invalid_constant))
        except json.JSONDecodeError as error:
            raise EvidenceError("invalid_event_json") from error
    require(bool(records), "empty_event_stream")
    return records


def metadata(records):
    tests, events, keys = {}, [], set()
    for record in records:
        require(isinstance(record, dict) and set(record) == {"kind", "payload", "version"}, "unknown_event_record")
        require(type(record["version"]) is int and record["version"] == 0, "unknown_event_schema")
        payload = record["payload"]
        require(isinstance(payload, dict), "invalid_event_payload")
        if record["kind"] == "event":
            events.append(payload)
            continue
        require(record["kind"] == "test", "unknown_record_kind")
        identifier, kind, name = payload.get("id"), payload.get("kind"), payload.get("name")
        require(isinstance(identifier, str) and identifier and identifier not in tests, "invalid_or_duplicate_test_id")
        require(kind in {"function", "suite"} and isinstance(name, str) and name, "unknown_test_metadata")
        if kind == "function":
            require(type(payload.get("isParameterized")) is bool, "unknown_parameterization")
            require(re.search(r"/[^/]+:\d+:\d+$", identifier), "missing_test_source_identity")
            key = identifier.rsplit("/", 1)[0]
            # Top-level functions have Module.function() rather than Module/function().
            if "/" not in key:
                require(key.endswith("." + name), "unknown_function_identity")
                key = key[:-(len(name) + 1)] + "/" + name
            require(key.endswith("/" + name) and CASE_PATTERN.fullmatch(key), "unknown_function_identity")
            require(key not in keys, "duplicate_function_identity")
            keys.add(key)
        else:
            key = identifier
        tests[identifier] = {"key": key, "kind": kind, "parameterized": payload.get("isParameterized"), "payload": payload}
    require(bool(keys), "missing_swift_testing_functions")
    return tests, events, keys


def validate_events(discovery_records, execution_records, expected):
    discovered, discovery_events, discovery_keys = metadata(discovery_records)
    require(not discovery_events and discovery_keys == expected, "swift_discovery_inventory_mismatch")
    runtime, events, runtime_keys = metadata(execution_records)
    require(runtime_keys == expected and set(runtime) == set(discovered), "swift_runtime_inventory_mismatch")
    argument_ids, argument_origins = {}, {}
    for identifier, test in runtime.items():
        require(all(test[field] == discovered[identifier][field] for field in ("key", "kind", "parameterized")),
                "swift_runtime_metadata_changed")
        cases = test["payload"].get("_testCases", [])
        require(isinstance(cases, list), "invalid_argument_inventory")
        if test["parameterized"]:
            require(bool(cases), "empty_parameterized_test")
        else:
            require(not cases, "unexpected_parameterized_cases")
        ids = set()
        for case in cases:
            require(isinstance(case, dict) and isinstance(case.get("id"), str) and case["id"], "missing_argument_id")
            require(case["id"] not in ids, "duplicate_argument_id")
            # Display names are not identities: distinct inputs can print identically.
            ids.add(case["id"])
        discovery_cases = discovered[identifier]["payload"].get("_testCases")
        if discovery_cases is not None:
            require(isinstance(discovery_cases, list), "invalid_discovery_argument_inventory")
            discovery_ids = set()
            for case in discovery_cases:
                require(isinstance(case, dict) and isinstance(case.get("id"), str) and case["id"], "invalid_discovery_argument_id")
                require(case["id"] not in discovery_ids, "duplicate_discovery_argument_id")
                discovery_ids.add(case["id"])
            require(discovery_ids == ids, "discovery_runtime_argument_mismatch")
        if test["parameterized"]:
            argument_origins[test["key"]] = ("discovery_and_runtime" if discovery_cases is not None else "runtime_metadata_only")
        argument_ids[identifier] = ids
    run_state, states, arguments = 0, {}, {}
    for event in events:
        kind, identifier = event.get("kind"), event.get("testID")
        require(kind in {"runStarted", "runEnded", "testStarted", "testEnded", "testCaseStarted", "testCaseEnded"},
                "failed_skipped_or_unknown_event:" + str(kind))
        require(set(event) <= {"kind", "instant", "messages", "testID", "_testCase"}, "unknown_event_fields")
        messages = event.get("messages")
        require(isinstance(messages, list), "missing_event_messages")
        require(all(isinstance(message, dict) and message.get("symbol") in {"default", "details", "pass"}
                    for message in messages), "nonpassing_event_message")
        if kind == "runStarted":
            require(run_state == 0 and identifier is None, "duplicate_or_invalid_run_start")
            run_state = 1
        elif kind == "runEnded":
            require(run_state == 1 and identifier is None, "invalid_run_end")
            require(any(message.get("symbol") == "pass" for message in messages), "missing_run_pass")
            run_state = 2
        else:
            require(run_state == 1 and identifier in runtime, "event_outside_run_or_unknown_test")
            if kind == "testStarted":
                require(identifier not in states, "duplicate_test_start")
                states[identifier] = "started"
            elif kind == "testEnded":
                require(states.get(identifier) == "started", "test_end_without_start")
                require(all(arguments.get((identifier, argument)) == "ended" for argument in argument_ids[identifier]),
                        "missing_completed_argument")
                states[identifier] = "ended"
            else:
                case = event.get("_testCase")
                require(isinstance(case, dict) and case.get("id") in argument_ids[identifier], "unknown_argument_id")
                require(states.get(identifier) == "started", "argument_outside_function")
                key = (identifier, case["id"])
                if kind == "testCaseStarted":
                    require(key not in arguments, "duplicate_argument_start")
                    arguments[key] = "started"
                else:
                    require(arguments.get(key) == "started", "argument_end_without_start")
                    arguments[key] = "ended"
    require(run_state == 2 and set(states) == set(runtime) and all(value == "ended" for value in states.values()),
            "incomplete_swift_run")
    return {"functions": sorted(runtime_keys), "argument_inventory_origin": argument_origins,
            "argument_inventory_limit": "Runtime-only argument metadata has no independent pre-run denominator; function coverage always uses pre-run discovery.",
            "argument_cases": [
        {"test": runtime[identifier]["key"], "argument_id": argument}
        for identifier in sorted(argument_ids) for argument in sorted(argument_ids[identifier])
    ]}


def source_snapshot():
    paths = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT)
    selected = {path for path in paths.decode().split("\0") if path and (path.startswith("Packages/ResearchVaultKit/") or path in {
        "scripts/verify-vault-tests.py", "scripts/verify-macos-evidence.py", "scripts/tests/test_vault_evidence.py", ".github/workflows/ci.yml"})}
    require("Packages/ResearchVaultKit/Package.resolved" in selected, "missing_dependency_lock")
    require(any(path.startswith("Packages/ResearchVaultKit/Tests/") for path in selected), "missing_test_sources")
    hashes = {}
    for relative in sorted(selected):
        path = ROOT / relative
        require(path.is_file() and not path.is_symlink(), "invalid_source_file:" + relative)
        hashes[relative] = sha256(path)
    return hashes


def framework_snapshot(path):
    path = path.resolve(strict=True)
    require(path.is_dir(), "missing_framework")
    files = {}
    for child in sorted(path.rglob("*")):
        relative = str(child.relative_to(path))
        if child.is_symlink():
            require(child.resolve(strict=True).is_relative_to(path), "escaping_framework_link")
            files[relative] = {"symlink": os.readlink(child)}
        elif child.is_file():
            files[relative] = {"sha256": sha256(child), "mode": child.stat().st_mode & 0o777}
        else:
            require(child.is_dir(), "unknown_framework_entry")
    require(bool(files), "empty_framework")
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-parent", type=pathlib.Path, required=True)
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    args = parser.parse_args()
    args.output_parent.mkdir(parents=True, exist_ok=True)
    output = pathlib.Path(tempfile.mkdtemp(prefix="throttle-vault-", dir=args.output_parent)).resolve()
    evidence, scratch = output / "evidence", output / "build"
    evidence.mkdir()
    commands, errors, sources, versions, completed, framework = [], [], {}, {}, {}, {}
    started, head = time.time(), None
    log = evidence / "runner.log"
    log.touch()
    try:
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        require(platform.system() == "Darwin", "macos_required")
        sources = source_snapshot()
        (evidence / "sources-before.json").write_text(json.dumps(sources, indent=2) + "\n")
        for name, command in {"xcode": ["xcodebuild", "-version"], "swift": ["swift", "--version"], "macos": ["sw_vers"]}.items():
            destination = evidence / (name + ".txt")
            run_command(command, ROOT, log, 60, commands, destination)
            versions[name] = destination.read_text().strip()
            require(bool(versions[name]), "missing_tool_version")
        require(shutil.disk_usage(output).free >= 4 * 1024 ** 3, "insufficient_disk_before_build")
        flags = package_flags(scratch, args.configuration)
        run_command(["swift", "build", *flags, "--build-tests"], ROOT, log, 1800, commands)
        bin_report = evidence / "bin-path.txt"
        run_command(["swift", "build", *flags, "--show-bin-path"], ROOT, log, 120, commands, bin_report)
        bin_path = pathlib.Path(bin_report.read_text().strip()).resolve(strict=True)
        require(bin_path.is_relative_to(scratch), "build_path_outside_unique_scratch")
        require(bin_path.name == args.configuration, "wrong_build_configuration_directory")
        original = bin_path / "SQLCipher.framework"
        staged = bin_path / "PackageFrameworks/SQLCipher.framework"
        framework = framework_snapshot(original)
        staged.parent.mkdir(exist_ok=True)
        run_command(["ditto", str(original), str(staged)], ROOT, log, 120, commands)
        require(framework_snapshot(staged) == framework, "sqlcipher_staging_mismatch")
        (evidence / "sqlcipher-manifest.json").write_text(json.dumps(framework, indent=2) + "\n")
        manifest = evidence / "package.json"
        run_command(["swift", "package", "--package-path", str(PACKAGE), "--scratch-path", str(scratch), "describe", "--type", "json"], ROOT, log, 120, commands, manifest)
        package_description = read_json(manifest)
        require(package_description.get("name") == "ResearchVaultKit", "wrong_package")
        targets = {target["name"] for target in package_description["targets"] if target["type"] == "test"}
        xctest_list, testing_list = evidence / "xctest-list.txt", evidence / "swift-testing-list.txt"
        discovery = evidence / "swift-testing-discovery.jsonl"
        # The deprecated spelling forwards native event-stream arguments to the
        # Testing entry point; `swift test list` currently has no such options.
        run_command(["swift", "test", *flags, "--skip-build", "--disable-swift-testing", "--list-tests"], ROOT, log, 120, commands, xctest_list)
        run_command(["swift", "test", *flags, "--skip-build", "--disable-xctest", "--list-tests", "--event-stream-output-path", str(discovery), "--event-stream-version", "0"], ROOT, log, 120, commands, testing_list)
        expected_xctest, expected_testing = inventory(xctest_list.read_text()), inventory(testing_list.read_text())
        require(not expected_xctest & expected_testing, "overlapping_framework_inventory")
        expected = expected_xctest | expected_testing
        require(REQUIRED_CASES <= expected, "missing_required_vault_cases")
        require({case.split(".", 1)[0] for case in expected} == targets, "test_target_inventory_mismatch")
        require(shutil.disk_usage(output).free >= 1024 ** 3, "insufficient_disk_before_tests")
        xctest_xml, testing_xml, events = evidence / "xctest.xml", evidence / "swift-testing.xml", evidence / "swift-testing-events.jsonl"
        # SwiftPM emits XCTest XML only with --parallel; one worker avoids
        # oversubscribing the expensive SQLCipher tests and still emits it.
        for label, command in (
            ("xctest", ["swift", "test", *flags, "--skip-build", "--disable-swift-testing", "--parallel", "--num-workers", "1", "--xunit-output", str(xctest_xml)]),
            ("swift_testing", ["swift", "test", *flags, "--skip-build", "--disable-xctest", "--xunit-output", str(testing_xml), "--event-stream-output-path", str(events), "--event-stream-version", "0"]),
        ):
            try:
                run_command(command, ROOT, log, 900, commands)
            except EvidenceError as error:
                # Preserve both engines' diagnostics even if the first fails.
                errors.append(label + ":" + str(error))
        for label, report, expected_cases in (("xctest", xctest_xml, expected_xctest), ("swift_testing_xml", testing_xml, expected_testing)):
            try:
                completed[label] = validate_xml(report.read_bytes(), expected_cases)
            except (EvidenceError, OSError) as error:
                errors.append(label + ":" + str(error))
        try:
            completed["swift_testing"] = validate_events(read_records(discovery), read_records(events), expected_testing)
        except (EvidenceError, OSError) as error:
            errors.append("swift_testing_events:" + str(error))
        if args.configuration == "release":
            products = release_products(bin_path)
            (evidence / "release-products.json").write_text(json.dumps(products, indent=2) + "\n")
            crash_output = evidence / "release-crash-recovery.jsonl"
            try:
                run_command(["/bin/sh", str(PACKAGE / "Scripts/verify-crash-recovery.sh"), "release", "--product-directory", str(bin_path)],
                            PACKAGE, log, 180, commands, crash_output)
                completed["release_crash_recovery"] = validate_crash_recovery(read_records(crash_output))
            except (EvidenceError, OSError) as error:
                errors.append("release_crash_recovery:" + str(error))
            try:
                # If the ephemeral invocation is accidentally enabled, stop
                # before attempting the direct path without the testing key.
                completed["release_ephemeral_refusal"] = run_cli_refusal(bin_path / "research-vault-mcp", output / "ephemeral-fixture",
                                                                          evidence, "release-rejects-ephemeral-key", commands, ephemeral=True)
                completed["release_direct_refusal"] = run_cli_refusal(bin_path / "research-vault-mcp", output / "direct-fixture",
                                                                       evidence, "release-rejects-direct-stdio", commands)
            except (EvidenceError, OSError) as error:
                errors.append("release_cli_refusal:" + str(error))
            require(release_products(bin_path) == products, "release_products_changed_during_gates")
        require(framework_snapshot(original) == framework_snapshot(staged) == framework, "sqlcipher_changed_during_tests")
    except (EvidenceError, OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as error:
        errors.append(str(error))
    if sources:
        try:
            after = source_snapshot()
            (evidence / "sources-after.json").write_text(json.dumps(after, indent=2) + "\n")
            require(after == sources, "source_changed_during_run")
        except (EvidenceError, OSError, subprocess.SubprocessError) as error:
            errors.append(str(error))
    artifacts = {str(path.relative_to(evidence)): sha256(path) for path in sorted(evidence.rglob("*")) if path.is_file()}
    receipt = {"schema_version": 1, "configuration": args.configuration,
               "scope": "ResearchVaultKit all discovered " + args.configuration + " package functions and runtime-announced arguments; Release also requires crash rollback and CLI refusal; no live Keychain, signed XPC or full Vault acceptance",
               "status": "PASS" if not errors else "FAIL", "head": head, "errors": errors,
               "duration_seconds": round(time.time() - started, 3), "source_sha256": sources,
               "tools": versions, "commands": commands, "completed": completed, "artifact_sha256": artifacts}
    (evidence / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({"status": receipt["status"], "receipt": str(evidence / "receipt.json"), "errors": errors}))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
