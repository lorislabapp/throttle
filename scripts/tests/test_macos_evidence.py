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


if __name__ == "__main__":
    unittest.main()
