"""Adversarial evidence cases; these never build or launch Throttle."""
import copy
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("macos_evidence", pathlib.Path(__file__).parents[1] / "verify-macos-evidence.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def enumeration():
    return {"errors": [], "values": [{"testPlan": "Throttle", "disabledTests": [],
            "enabledTests": [{"identifier": "ThrottleTests/" + case} for case in sorted(runner.REQUIRED_CASES)]}]}


def reports():
    cases = [{"nodeType": "Test Case", "nodeIdentifier": case,
              "result": "Skipped" if case in runner.ALLOWED_SKIPS else "Passed"}
             for case in sorted(runner.REQUIRED_CASES)]
    count = len(cases)
    summary = {"result": "Passed", "totalTestCount": count, "passedTests": count - 5,
               "skippedTests": 5, "failedTests": 0, "expectedFailures": 0, "testFailures": []}
    tree = {"testNodes": [{"nodeType": "Test Plan", "name": "Throttle", "result": "Passed", "children": [
        {"nodeType": "Unit test bundle", "name": "ThrottleTests", "result": "Passed", "children": cases}]}]}
    return summary, tree


def leaves(tree):
    return tree["testNodes"][0]["children"][0]["children"]


class MacOSEvidenceTests(unittest.TestCase):
    def test_native_enumeration_and_five_explicit_skips_pass(self):
        expected = runner.inventory_from_enumeration(enumeration())
        errors, cases = runner.validate_reports(*reports(), expected)
        self.assertEqual(errors, [])
        self.assertEqual(set(cases), expected)

    def test_enumeration_rejects_disabled_duplicate_missing_and_unknown_cases(self):
        baseline = enumeration()
        variants = [None, {}, {"errors": [], "values": []}]
        for key, value in [("disabledTests", [{"identifier": "hidden"}]), ("enabledTests", []), ("testPlan", "Other")]:
            report = copy.deepcopy(baseline)
            report["values"][0][key] = value
            variants.append(report)
        for extra in [baseline["values"][0]["enabledTests"][0], {"identifier": "OtherTests/test()"}, {},
                      {"identifier": "ThrottleTests/Unknown/not_a_case"}]:
            report = copy.deepcopy(baseline)
            report["values"][0]["enabledTests"].append(extra)
            variants.append(report)
        report = copy.deepcopy(baseline)
        report["values"][0]["enabledTests"].pop()
        variants.append(report)
        for report in variants:
            with self.subTest(report=report), self.assertRaises(runner.EvidenceError):
                runner.inventory_from_enumeration(report)

    def test_empty_unknown_truncated_or_failed_summary_cannot_pass(self):
        for summary in [None, {}, {"result": "Unknown"}]:
            self.assertTrue(runner.validate_reports(summary, reports()[1], runner.REQUIRED_CASES)[0])
        for key, value in [("result", "Failed"), ("testFailures", [{}]), ("failedTests", 1), ("expectedFailures", 1),
                           ("totalTestCount", "11"), ("passedTests", True), ("skippedTests", -1)]:
            summary, tree = reports()
            summary[key] = value
            self.assertTrue(runner.validate_reports(summary, tree, runner.REQUIRED_CASES)[0], (key, value))

    def test_missing_case_fails_even_with_consistent_green_summary(self):
        summary, tree = reports()
        removed = leaves(tree).pop()
        summary["totalTestCount"] -= 1
        summary["passedTests" if removed["result"] == "Passed" else "skippedTests"] -= 1
        errors, _ = runner.validate_reports(summary, tree, runner.REQUIRED_CASES)
        self.assertIn("missing_case:" + removed["nodeIdentifier"], errors)

    def test_extra_case_duplicate_and_wrong_target_fail(self):
        for mutation in ("extra", "duplicate", "wrong_target"):
            summary, tree = reports()
            if mutation == "wrong_target":
                tree["testNodes"][0]["children"][0]["name"] = "OtherTests"
            else:
                extra = copy.deepcopy(leaves(tree)[0])
                if mutation == "extra":
                    extra["nodeIdentifier"] = "UnexpectedTests/test_extra()"
                leaves(tree).append(extra)
            self.assertTrue(runner.validate_reports(summary, tree, runner.REQUIRED_CASES)[0])

    def test_unknown_status_expected_failure_and_unexpected_skip_fail(self):
        for status in ["Unknown", "Failed", "Expected Failure", "Not Run", "Skipped", None, {}, []]:
            summary, tree = reports()
            case = next(case for case in leaves(tree) if case["result"] == "Passed")
            case["result"] = status
            self.assertTrue(runner.validate_reports(summary, tree, runner.REQUIRED_CASES)[0], status)

    def test_green_container_cannot_hide_failure_and_failed_container_cannot_hide_green_cases(self):
        summary, tree = reports()
        leaves(tree)[0]["result"] = "Failed"
        self.assertTrue(runner.validate_reports(summary, tree, runner.REQUIRED_CASES)[0])
        summary, tree = reports()
        tree["testNodes"][0]["result"] = "Failed"
        self.assertTrue(runner.validate_reports(summary, tree, runner.REQUIRED_CASES)[0])

    def test_malformed_tree_empty_inventory_and_count_mismatch_fail(self):
        for tree in [None, {}, {"testNodes": []}, {"testNodes": [None]}, {"testNodes": [{"children": {}}]}]:
            self.assertTrue(runner.validate_reports(reports()[0], tree, runner.REQUIRED_CASES)[0])
        self.assertTrue(runner.validate_reports(*reports(), set())[0])
        summary, tree = reports()
        summary["passedTests"] += 1
        self.assertIn("summary_tree_mismatch:passedTests", runner.validate_reports(summary, tree, runner.REQUIRED_CASES)[0])

    def test_warnings_and_recorded_skip_messages_are_not_extra_tests(self):
        summary, tree = reports()
        leaves(tree)[0]["children"] = [{"nodeType": "Runtime Warning", "name": "QoS warning"}]
        skipped = next(case for case in leaves(tree) if case["result"] == "Skipped")
        skipped["children"] = [{"nodeType": "Skip Message", "name": "Requires opt-in"}]
        self.assertEqual(runner.validate_reports(summary, tree, runner.REQUIRED_CASES)[0], [])

    def test_skip_reason_filed_as_failure_message_is_accepted_only_under_an_allowed_skip(self):
        # Xcode 26.6 labels the recorded skip reason "Failure Message" (run 34279369825).
        summary, tree = reports()
        skipped = next(case for case in leaves(tree) if case["result"] == "Skipped")
        skipped["children"] = [{"nodeType": "Failure Message", "name": "Test skipped - Requires opt-in"}]
        self.assertEqual(runner.validate_reports(summary, tree, runner.REQUIRED_CASES)[0], [])
        for spelling in ("Failure Message", "Skip Message"):
            summary, tree = reports()
            passed = next(case for case in leaves(tree) if case["result"] == "Passed")
            passed["children"] = [{"nodeType": spelling, "name": "Assertion text hidden under a green case"}]
            self.assertIn("message_outside_allowed_skip:Assertion text hidden under a green case",
                          runner.validate_reports(summary, tree, runner.REQUIRED_CASES)[0])
        summary, tree = reports()
        skipped = next(case for case in leaves(tree) if case["result"] == "Skipped")
        skipped["children"] = [{"nodeType": "Failure Message", "name": "Nested", "children": [
            {"nodeType": "Failure Message", "name": "Deeper"}]}]
        self.assertIn("message_outside_allowed_skip:Deeper", runner.validate_reports(summary, tree, runner.REQUIRED_CASES)[0])

    def test_opt_in_test_may_pass_instead_of_skip_but_may_not_disappear(self):
        summary, tree = reports()
        skipped = next(case for case in leaves(tree) if case["result"] == "Skipped")
        skipped["result"] = "Passed"
        summary["passedTests"] += 1
        summary["skippedTests"] -= 1
        self.assertEqual(runner.validate_reports(summary, tree, runner.REQUIRED_CASES)[0], [])

    def test_json_duplicate_keys_nonfinite_and_truncation_fail(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "report.json"
            for content in ['{"result":"Failed","result":"Passed"}', '{"count":NaN}', '{"result":']:
                path.write_text(content)
                with self.assertRaises((runner.EvidenceError, json.JSONDecodeError)):
                    runner.read_json(path)

    def test_command_exit_zero_does_not_make_missing_report_pass(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            commands = []
            runner.run_command([sys.executable, "-c", "pass"], root, root / "log", 5, commands)
            self.assertEqual(commands[0]["exit_code"], 0)
            with self.assertRaises(FileNotFoundError):
                runner.read_json(root / "summary.json")

    def test_nonzero_command_and_timeout_are_failures(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            for code, timeout, expected in [("raise SystemExit(7)", 5, 7), ("import time; time.sleep(10)", 0.05, 124)]:
                commands = []
                with self.assertRaises(runner.EvidenceError):
                    runner.run_command([sys.executable, "-c", code], root, root / "log", timeout, commands)
                self.assertEqual(commands[0]["exit_code"], expected)

    def test_snapshot_includes_ignored_generated_project_and_detects_changed_inputs(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            test = root / "ThrottleTests/Example.swift"
            project = root / "Throttle.xcodeproj/project.pbxproj"
            for path in [test, project]:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("original")
            with mock.patch.object(runner.subprocess, "check_output", return_value=b"ThrottleTests/Example.swift\0"):
                before = runner.source_snapshot(root)
                self.assertIn("Throttle.xcodeproj/project.pbxproj", before)
                project.write_text("changed")
                self.assertNotEqual(before, runner.source_snapshot(root))
                test.unlink()
                with self.assertRaises(runner.EvidenceError):
                    runner.source_snapshot(root)


def ios_enumeration():
    return {"errors": [], "values": [{"testPlan": "ThrottleiOS", "disabledTests": [],
            "enabledTests": [{"identifier": "ThrottleiOSTests/" + case} for case in sorted(runner.IOS_REQUIRED_CASES)]}]}


def ios_reports():
    # Native xcresulttool shape read from RecoveredMacTests.xcresult, 2026-09-08,
    # including suites, identifier URLs and localized duration. Only scheme,
    # bundle and case names are remapped here. This is not an iOS runtime receipt.
    suite_nodes = {}
    for case in sorted(runner.IOS_REQUIRED_CASES):
        suite, name = case.split("/")
        prefix = "test://com.apple.xcode/ThrottleiOS/ThrottleiOSTests/"
        suite_nodes.setdefault(suite, {"name": suite, "nodeType": "Test Suite", "result": "Passed",
                                      "nodeIdentifierURL": prefix + suite, "children": []})["children"].append({
            "duration": "0,0013s", "durationInSeconds": 0.0012940168380737305,
            "name": name, "nodeIdentifier": case, "nodeIdentifierURL": prefix + case.removesuffix("()"),
            "nodeType": "Test Case", "result": "Passed",
        })
    count = len(runner.IOS_REQUIRED_CASES)
    summary = {"result": "Passed", "totalTestCount": count, "passedTests": count,
               "skippedTests": 0, "failedTests": 0, "expectedFailures": 0, "testFailures": []}
    tree = {"testNodes": [{"nodeType": "Test Plan", "name": "ThrottleiOS", "result": "Passed", "children": [
        {"nodeType": "Unit test bundle", "name": "ThrottleiOSTests", "result": "Passed",
         "nodeIdentifierURL": "test://com.apple.xcode/ThrottleiOS/ThrottleiOSTests", "children": list(suite_nodes.values())}]}]}
    return summary, tree


def ios_leaves(tree):
    return [case for suite in tree["testNodes"][0]["children"][0]["children"] for case in suite["children"]]


class IOSEvidenceTests(unittest.TestCase):
    def test_remapped_native_xcode_shape_requires_all_four_isolation_cases(self):
        expected = runner.inventory_from_enumeration(ios_enumeration(), scheme="ThrottleiOS")
        errors, cases = runner.validate_reports(*ios_reports(), expected, scheme="ThrottleiOS")
        self.assertEqual(errors, [])
        self.assertEqual(set(cases), runner.IOS_REQUIRED_CASES)
        self.assertEqual(len(cases), 4)

    def test_schemes_and_bundles_cannot_be_exchanged(self):
        for report, scheme in ((ios_enumeration(), "Throttle"), (enumeration(), "ThrottleiOS")):
            with self.assertRaises(runner.EvidenceError):
                runner.inventory_from_enumeration(report, scheme=scheme)
        report = ios_enumeration()
        report["values"][0]["enabledTests"][0]["identifier"] = "ThrottleTests/" + sorted(runner.IOS_REQUIRED_CASES)[0]
        with self.assertRaises(runner.EvidenceError):
            runner.inventory_from_enumeration(report, scheme="ThrottleiOS")

    def test_unknown_scheme_is_rejected_by_every_profile_entrypoint(self):
        with self.assertRaises(runner.EvidenceError):
            runner.inventory_from_enumeration(ios_enumeration(), scheme="Other")
        with self.assertRaises(runner.EvidenceError):
            runner.validate_reports(*ios_reports(), runner.IOS_REQUIRED_CASES, scheme="Other")
        with self.assertRaises(runner.EvidenceError):
            runner.source_snapshot(scheme="Other")

    def test_each_required_isolation_case_must_be_enumerated(self):
        for case in runner.IOS_REQUIRED_CASES:
            report = ios_enumeration()
            report["values"][0]["enabledTests"] = [test for test in report["values"][0]["enabledTests"]
                                                   if test["identifier"] != "ThrottleiOSTests/" + case]
            with self.subTest(case=case), self.assertRaisesRegex(runner.EvidenceError, "missing_required"):
                runner.inventory_from_enumeration(report, scheme="ThrottleiOS")

    def test_disabled_duplicate_and_multiple_plan_enumerations_fail(self):
        for mutation in ("disabled", "duplicate", "multiple_plans"):
            report = ios_enumeration()
            if mutation == "disabled":
                report["values"][0]["disabledTests"] = [{"identifier": "hidden"}]
            elif mutation == "duplicate":
                report["values"][0]["enabledTests"].append(report["values"][0]["enabledTests"][0])
            else:
                report["values"].append(copy.deepcopy(report["values"][0]))
            with self.subTest(mutation=mutation), self.assertRaises(runner.EvidenceError):
                runner.inventory_from_enumeration(report, scheme="ThrottleiOS")

    def test_wrong_result_plan_and_bundle_cannot_hide_green_cases(self):
        for mutation in ("plan", "bundle", "multiple_plans", "missing_plan"):
            summary, tree = ios_reports()
            if mutation == "plan":
                tree["testNodes"][0]["name"] = "Throttle"
            elif mutation == "bundle":
                tree["testNodes"][0]["children"][0]["name"] = "ThrottleTests"
            elif mutation == "multiple_plans":
                tree["testNodes"].append(copy.deepcopy(tree["testNodes"][0]))
            else:
                tree["testNodes"] = tree["testNodes"][0]["children"]
            self.assertTrue(runner.validate_reports(summary, tree, runner.IOS_REQUIRED_CASES, scheme="ThrottleiOS")[0], mutation)

    def test_ios_skips_fail_even_with_consistent_green_counts(self):
        summary, tree = ios_reports()
        ios_leaves(tree)[0]["result"] = "Skipped"
        summary["passedTests"] -= 1
        summary["skippedTests"] += 1
        errors, _ = runner.validate_reports(summary, tree, runner.IOS_REQUIRED_CASES, scheme="ThrottleiOS")
        self.assertTrue(any(error.startswith("unexpected_skip:") for error in errors))

    def test_skipped_suite_or_skip_message_cannot_hide_behind_passing_cases(self):
        for mutation in ("suite", "message"):
            summary, tree = ios_reports()
            if mutation == "suite":
                tree["testNodes"][0]["children"][0]["children"][0]["result"] = "Skipped"
            else:
                ios_leaves(tree)[0]["children"] = [{"nodeType": "Skip Message", "name": "optional"}]
            self.assertTrue(runner.validate_reports(summary, tree, runner.IOS_REQUIRED_CASES, scheme="ThrottleiOS")[0])

    def test_missing_new_discovered_case_cannot_pass_required_subset(self):
        report = ios_enumeration()
        report["values"][0]["enabledTests"].append({"identifier": "ThrottleiOSTests/NewTests/testNewBehavior()"})
        expected = runner.inventory_from_enumeration(report, scheme="ThrottleiOS")
        errors, _ = runner.validate_reports(*ios_reports(), expected, scheme="ThrottleiOS")
        self.assertIn("missing_case:NewTests/testNewBehavior()", errors)

    def test_macos_skip_allowlist_does_not_leak_into_ios(self):
        summary, tree = ios_reports()
        case = sorted(runner.ALLOWED_SKIPS)[0]
        ios_leaves(tree)[0].update(nodeIdentifier=case, result="Skipped")
        errors, _ = runner.validate_reports(summary, tree, runner.IOS_REQUIRED_CASES | {case}, scheme="ThrottleiOS")
        self.assertIn("unexpected_skip:" + case, errors)
        self.assertEqual(runner.profile_for_scheme("ThrottleiOS")["skips"], {})
        self.assertEqual(len(runner.profile_for_scheme("Throttle")["skips"]), 5)

    def test_ios_snapshot_covers_companion_widget_shared_and_generated_scheme(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            paths = ["ThrottleiOS/App.swift", "ThrottleiOSTests/Example.swift", "ThrottleiOSWidget/Widget.swift",
                     "ThrottleShared/Shared.swift", "ThrottleTests/Mac.swift", "Throttle/Mac.swift",
                     "Throttle.xcodeproj/xcshareddata/xcschemes/ThrottleiOS.xcscheme"]
            for name in paths:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("original")
            tracked = "\0".join(paths[:-1]).encode()
            with mock.patch.object(runner.subprocess, "check_output", return_value=tracked):
                before = runner.source_snapshot(root, scheme="ThrottleiOS")
                self.assertEqual(set(before), set(paths[:4] + paths[-1:]))
                # The macOS source selection remains unchanged.
                self.assertEqual(set(runner.source_snapshot(root)), set(paths[3:]))
                (root / "ThrottleiOSWidget/Widget.swift").write_text("changed")
                self.assertNotEqual(before, runner.source_snapshot(root, scheme="ThrottleiOS"))
                (root / "ThrottleiOSTests/Example.swift").unlink()
                with self.assertRaises(runner.EvidenceError):
                    runner.source_snapshot(root, scheme="ThrottleiOS")


class IOSSimulatorSelectionTests(unittest.TestCase):
    FIRST = "A0B1C2D3-E4F5-4789-ABCD-012345678901"
    SECOND = "B0B1C2D3-E4F5-4789-ABCD-012345678902"

    def inventory(self):
        return {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [{"name": "iPhone 17", "udid": self.FIRST, "isAvailable": True}],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-6": [{"name": "iPhone 17 Pro", "udid": self.SECOND, "isAvailable": True}],
            "com.apple.CoreSimulator.SimRuntime.tvOS-26-6": [{"name": "Apple TV", "udid": "ignored", "isAvailable": True}],
        }}

    def test_latest_available_iphone_is_selected_and_recorded(self):
        destination, device = runner.simulator_destination(self.inventory())
        self.assertEqual(destination, "platform=iOS Simulator,id=" + self.SECOND)
        self.assertEqual(device, {"udid": self.SECOND, "name": "iPhone 17 Pro", "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-26-6"})
        selected, _ = runner.simulator_destination(self.inventory(), "platform=iOS Simulator,id=" + self.FIRST)
        self.assertTrue(selected.endswith(self.FIRST))

    def test_physical_generic_named_and_unavailable_destinations_are_rejected(self):
        for destination in ("platform=iOS,id=" + self.FIRST, "generic/platform=iOS Simulator", "platform=iOS Simulator,name=iPhone 17",
                            "platform=macOS", "platform=iOS Simulator,id=C0B1C2D3-E4F5-4789-ABCD-012345678903"):
            with self.subTest(destination=destination), self.assertRaises(runner.EvidenceError):
                runner.simulator_destination(self.inventory(), destination)

    def test_empty_unknown_unavailable_duplicate_and_malformed_inventories_fail(self):
        for report in (None, {}, {"devices": {}}, {"devices": []}):
            with self.assertRaises(runner.EvidenceError):
                runner.simulator_destination(report)
        report = self.inventory()
        for devices in report["devices"].values():
            for device in devices:
                device["isAvailable"] = False
        with self.assertRaises(runner.EvidenceError):
            runner.simulator_destination(report)
        report = self.inventory()
        report["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-26-6"][0]["udid"] = self.FIRST
        with self.assertRaisesRegex(runner.EvidenceError, "duplicate_simulator"):
            runner.simulator_destination(report)
        report["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-26-6"][0]["udid"] = "not-a-uuid"
        with self.assertRaisesRegex(runner.EvidenceError, "invalid_simulator_uuid"):
            runner.simulator_destination(report)

    def test_build_arguments_remain_ad_hoc_without_physical_destinations_or_test_filters(self):
        output = pathlib.Path("/private/tmp/isolated-evidence-fixture")
        for scheme, destination in (("Throttle", "platform=macOS,arch=" + runner.platform.machine()),
                                    ("ThrottleiOS", "platform=iOS Simulator,id=" + self.FIRST)):
            command = runner.build_arguments(output, scheme, destination)
            self.assertEqual(command[command.index("-scheme") + 1], scheme)
            self.assertEqual(command[command.index("-destination") + 1], destination)
            self.assertEqual(command[command.index("-configuration") + 1], "Debug")
            self.assertEqual(command[command.index("-derivedDataPath") + 1], str(output / "DerivedData"))
            for setting in ("CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=", "PROVISIONING_PROFILE=",
                            "PROVISIONING_PROFILE_SPECIFIER=", "CODE_SIGN_ENTITLEMENTS=", "CODE_SIGNING_ALLOWED=YES"):
                self.assertIn(setting, command)
            self.assertFalse(any("only-testing" in argument or "skip-testing" in argument for argument in command))
        with self.assertRaises(runner.EvidenceError):
            runner.build_arguments(output, "ThrottleiOS", "platform=iOS,id=" + self.FIRST)
        with self.assertRaises(runner.EvidenceError):
            runner.build_arguments(output, "Throttle", "platform=iOS Simulator,id=" + self.FIRST)


if __name__ == "__main__":
    unittest.main()
