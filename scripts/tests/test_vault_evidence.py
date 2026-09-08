"""Adversarial checks against native SwiftPM XML and event-stream samples."""
import copy
import importlib.util
import json
import pathlib
import tempfile
import unittest
import xml.etree.ElementTree as ET


ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("vault_evidence", ROOT / "scripts/verify-vault-tests.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)
HISTORY = ROOT / "docs/testing/evidence/2026-09-08-integration"


class VaultXMLEvidenceTests(unittest.TestCase):
    def fixture(self, filename="vault-swift-testing.xml"):
        data = (HISTORY / filename).read_bytes()
        cases = {case.get("classname") + "/" + case.get("name") for case in ET.fromstring(data).iter("testcase")}
        return data, cases

    def reject_mutation(self, mutate):
        data, expected = self.fixture()
        root = ET.fromstring(data)
        mutate(root)
        with self.assertRaises(validator.EvidenceError):
            validator.validate_xml(ET.tostring(root), expected)

    def test_real_historical_xctest_and_swift_testing_shapes(self):
        for filename, count in (("vault-xctest.xml", 42), ("vault-swift-testing.xml", 107)):
            with self.subTest(filename=filename):
                data, expected = self.fixture(filename)
                self.assertEqual(len(validator.validate_xml(data, expected)), count)

    def test_historical_inventory_includes_ocr_and_xpc(self):
        _, expected = self.fixture()
        self.assertIn("ResearchVaultIngestionTests.ResearchDocumentTextExtractorTests/scannedPDFIsRecoveredByOCR()", expected)
        self.assertIn("ResearchVaultXPCTests.ResearchVaultXPCTests/ownerServiceRejectsMalformedBytes()", expected)

    def test_missing_case_fails_even_when_summary_is_rewritten_green(self):
        def mutate(root):
            root[0].remove(root[0][0])
            root[0].set("tests", "106")
        self.reject_mutation(mutate)

    def test_duplicate_case_fails_even_when_summary_matches(self):
        def mutate(root):
            root[0].append(copy.deepcopy(root[0][0]))
            root[0].set("tests", "108")
        self.reject_mutation(mutate)

    def test_unknown_case_identity_is_rejected(self):
        self.reject_mutation(lambda root: root[0][0].set("name", "invented()"))

    def test_failure_skip_error_and_unknown_nodes_are_rejected(self):
        for tag in ("failure", "error", "skipped", "unknown"):
            with self.subTest(tag=tag):
                self.reject_mutation(lambda root: ET.SubElement(root[0][0], tag))

    def test_nonzero_or_missing_failure_counters_are_rejected(self):
        for field in ("failures", "errors", "skipped", "tests"):
            with self.subTest(field=field):
                self.reject_mutation(lambda root: root[0].set(field, "1"))
        self.reject_mutation(lambda root: root[0].attrib.pop("failures"))

    def test_unknown_status_or_disabled_attribute_fails_closed(self):
        self.reject_mutation(lambda root: root[0][0].set("status", "disabled"))
        self.reject_mutation(lambda root: root[0].set("disabled", "1"))

    def test_unknown_text_in_a_case_fails_closed(self):
        self.reject_mutation(lambda root: setattr(root[0][0], "text", "failed outside a standard node"))

    def test_invalid_or_empty_reports_fail_closed(self):
        _, expected = self.fixture()
        for data in (b"", b"<testsuites>", b"<testsuites/>", b"<other/>",
                     b'<!DOCTYPE testsuites [<!ENTITY a "bad">]><testsuites/>'):
            with self.subTest(data=data), self.assertRaises(validator.EvidenceError):
                validator.validate_xml(data, expected)
        data, _ = self.fixture()
        with self.assertRaises(validator.EvidenceError):
            validator.validate_xml(data, set())

    def test_nonfinite_and_negative_times_are_rejected(self):
        for duration in ("nan", "inf", "-1", "not-a-time"):
            with self.subTest(duration=duration):
                self.reject_mutation(lambda root: root[0][0].set("time", duration))
                self.reject_mutation(lambda root: root[0].set("time", duration))

    def test_inventory_is_strict_nonempty_and_deduplicated(self):
        self.assertEqual(validator.inventory("Vault.Suite/parameter(kind:)\nVault.Class/testMethod\n"),
                         {"Vault.Suite/parameter(kind:)", "Vault.Class/testMethod"})
        for text in ("", "Vault.Class/testMethod\nVault.Class/testMethod\n", "warning: no tests", "Vault.Class/testMethod\n\n"):
            with self.subTest(text=text), self.assertRaises(validator.EvidenceError):
                validator.inventory(text)


class VaultNativeEventTests(unittest.TestCase):
    def setUp(self):
        self.discovery = copy.deepcopy(NATIVE_DISCOVERY)
        self.execution = copy.deepcopy(NATIVE_EXECUTION)
        self.expected = {"ProbeTests.SampleSuite/plain()", "ProbeTests.SampleSuite/parameter(value:)"}

    def validate(self):
        return validator.validate_events(self.discovery, self.execution, self.expected)

    def events(self, kind):
        return [record for record in self.execution if record["kind"] == "event" and record["payload"]["kind"] == kind]

    def argument_metadata(self):
        return next(record["payload"] for record in self.execution if record["kind"] == "test" and record["payload"].get("isParameterized"))

    def test_native_capture_proves_functions_and_each_distinct_argument(self):
        proof = self.validate()
        self.assertEqual(proof["functions"], sorted(self.expected))
        self.assertEqual(len(proof["argument_cases"]), 2)
        self.assertEqual(set(proof["argument_inventory_origin"].values()), {"runtime_metadata_only"})

    def test_discovery_argument_ids_are_an_independent_required_denominator_when_available(self):
        discovery_parameter = next(record["payload"] for record in self.discovery if record["payload"].get("isParameterized"))
        discovery_parameter["_testCases"] = copy.deepcopy(self.argument_metadata()["_testCases"])
        self.assertEqual(set(self.validate()["argument_inventory_origin"].values()), {"discovery_and_runtime"})
        omitted = self.argument_metadata()["_testCases"].pop()["id"]
        self.execution = [record for record in self.execution if record["payload"].get("_testCase", {}).get("id") != omitted]
        with self.assertRaisesRegex(validator.EvidenceError, "discovery_runtime_argument_mismatch"):
            self.validate()

    def test_lazy_discovery_cannot_prove_an_unannounced_runtime_argument(self):
        # This is an explicit limitation, not an independent argument count:
        # the real --list-tests capture contains no lazy argument inventory.
        omitted = self.argument_metadata()["_testCases"].pop()["id"]
        self.execution = [record for record in self.execution if record["payload"].get("_testCase", {}).get("id") != omitted]
        proof = self.validate()
        self.assertEqual(len(proof["argument_cases"]), 1)
        self.assertEqual(set(proof["argument_inventory_origin"].values()), {"runtime_metadata_only"})
        self.assertIn("no independent", proof["argument_inventory_limit"])

    def test_identical_argument_display_names_are_not_duplicate_identities(self):
        for case in self.argument_metadata()["_testCases"]:
            case["displayName"] = "same display"
        for kind in ("testCaseStarted", "testCaseEnded"):
            for event in self.events(kind):
                event["payload"]["_testCase"]["displayName"] = "same display"
        self.assertEqual(len(self.validate()["argument_cases"]), 2)

    def test_missing_argument_start_and_end_fails_despite_passing_function(self):
        argument = self.argument_metadata()["_testCases"][0]["id"]
        self.execution = [record for record in self.execution if record["payload"].get("_testCase", {}).get("id") != argument]
        with self.assertRaisesRegex(validator.EvidenceError, "missing_completed_argument"):
            self.validate()

    def test_missing_argument_end_is_incomplete(self):
        self.execution.remove(self.events("testCaseEnded")[0])
        with self.assertRaises(validator.EvidenceError):
            self.validate()

    def test_missing_parameter_inventory_is_not_a_pass(self):
        self.argument_metadata().pop("_testCases")
        with self.assertRaisesRegex(validator.EvidenceError, "empty_parameterized_test"):
            self.validate()

    def test_duplicate_argument_metadata_is_rejected(self):
        cases = self.argument_metadata()["_testCases"]
        cases.append(copy.deepcopy(cases[0]))
        with self.assertRaisesRegex(validator.EvidenceError, "duplicate_argument_id"):
            self.validate()

    def test_unknown_argument_and_duplicate_start_are_rejected(self):
        self.events("testCaseStarted")[0]["payload"]["_testCase"]["id"] = "unknown"
        with self.assertRaisesRegex(validator.EvidenceError, "unknown_argument_id"):
            self.validate()
        self.setUp()
        event = self.events("testCaseStarted")[0]
        self.execution.insert(self.execution.index(event), copy.deepcopy(event))
        with self.assertRaisesRegex(validator.EvidenceError, "duplicate_argument_start"):
            self.validate()

    def test_missing_function_is_not_hidden_by_complete_xml(self):
        identifier = next(record["payload"]["id"] for record in self.discovery if record["payload"].get("name") == "plain()")
        self.execution = [record for record in self.execution if record["payload"].get("testID") != identifier]
        with self.assertRaisesRegex(validator.EvidenceError, "incomplete_swift_run"):
            self.validate()

    def test_unknown_schema_is_rejected(self):
        self.execution[0]["version"] = 1
        with self.assertRaisesRegex(validator.EvidenceError, "unknown_event_schema"):
            self.validate()

    def test_issue_skip_and_unknown_event_fail_closed(self):
        for kind in ("issueRecorded", "testSkipped", "unknownKind"):
            self.setUp()
            self.events("testStarted")[0]["payload"]["kind"] = kind
            with self.subTest(kind=kind), self.assertRaises(validator.EvidenceError):
                self.validate()

    def test_nonpassing_message_fails_closed(self):
        self.events("testEnded")[0]["payload"]["messages"] = [{"symbol": "fail", "text": "failure"}]
        with self.assertRaisesRegex(validator.EvidenceError, "nonpassing_event_message"):
            self.validate()

    def test_truncation_run_replay_and_wrong_inventory_fail(self):
        self.execution.pop()
        with self.assertRaises(validator.EvidenceError):
            self.validate()
        self.setUp()
        self.execution.append(copy.deepcopy(self.events("runEnded")[0]))
        with self.assertRaises(validator.EvidenceError):
            self.validate()
        self.setUp()
        self.expected.add("ProbeTests.SampleSuite/missing()")
        with self.assertRaises(validator.EvidenceError):
            self.validate()

    def test_function_end_cannot_precede_argument_completion(self):
        end = self.events("testCaseEnded")[0]
        self.execution.remove(end)
        self.execution.insert(-1, end)
        with self.assertRaisesRegex(validator.EvidenceError, "missing_completed_argument"):
            self.validate()

    def test_duplicate_json_keys_nonfinite_or_empty_stream_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "events.jsonl"
            for data in ('{"kind":"test","kind":"event"}\n', '{"value":NaN}\n', '', '\n', '{'):
                path.write_text(data)
                with self.subTest(data=data), self.assertRaises(validator.EvidenceError):
                    validator.read_records(path)


class VaultFrameworkEvidenceTests(unittest.TestCase):
    def test_staging_manifest_detects_changed_bytes_mode_and_links(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "Versions/A").mkdir(parents=True)
            binary = root / "Versions/A/SQLCipher"
            binary.write_bytes(b"fixture-not-a-real-framework")
            (root / "Versions/Current").symlink_to("A")
            (root / "SQLCipher").symlink_to("Versions/Current/SQLCipher")
            before = validator.framework_snapshot(root)
            binary.write_bytes(b"tampered")
            self.assertNotEqual(before, validator.framework_snapshot(root))
            before = validator.framework_snapshot(root)
            binary.chmod(0o755)
            self.assertNotEqual(before, validator.framework_snapshot(root))
            (root / "SQLCipher").unlink()
            (root / "SQLCipher").symlink_to("/bin/sh")
            with self.assertRaisesRegex(validator.EvidenceError, "escaping_framework_link"):
                validator.framework_snapshot(root)

    def test_empty_framework_is_not_evidence(self):
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(validator.EvidenceError):
            validator.framework_snapshot(pathlib.Path(directory))


# Captured by Swift 6.4 / Testing 2078, 2026-09-08, from a real tiny package:
# @Suite struct SampleSuite { @Test("Pretty plain") func plain() { ... }
# @Test(arguments: ["a", "b"]) func parameter(value: String) { ... } }
# Deliberately retain the opaque argument IDs and native display-name distinction.
NATIVE_DISCOVERY = json.loads(r'''[{"kind":"test","payload":{"id":"ProbeTests.SampleSuite","kind":"suite","name":"SampleSuite","sourceLocation":{"_filePath":"/private/tmp/throttle-vault-schema-probe-xanw33lr/Tests/ProbeTests/ProbeTests.swift","column":2,"fileID":"ProbeTests/ProbeTests.swift","line":3}},"version":0},{"kind":"test","payload":{"_parameters":[{"name":"value","typeName":"Swift.String"}],"id":"ProbeTests.SampleSuite/parameter(value:)/ProbeTests.swift:5:3","isParameterized":true,"kind":"function","name":"parameter(value:)","sourceLocation":{"_filePath":"/private/tmp/throttle-vault-schema-probe-xanw33lr/Tests/ProbeTests/ProbeTests.swift","column":3,"fileID":"ProbeTests/ProbeTests.swift","line":5}},"version":0},{"kind":"test","payload":{"displayName":"Pretty plain","id":"ProbeTests.SampleSuite/plain()/ProbeTests.swift:4:3","isParameterized":false,"kind":"function","name":"plain()","sourceLocation":{"_filePath":"/private/tmp/throttle-vault-schema-probe-xanw33lr/Tests/ProbeTests/ProbeTests.swift","column":3,"fileID":"ProbeTests/ProbeTests.swift","line":4}},"version":0}]''')
NATIVE_EXECUTION = json.loads(r'''[{"kind":"test","payload":{"id":"ProbeTests.SampleSuite","kind":"suite","name":"SampleSuite","sourceLocation":{"_filePath":"/private/tmp/throttle-vault-schema-probe-xanw33lr/Tests/ProbeTests/ProbeTests.swift","column":2,"fileID":"ProbeTests/ProbeTests.swift","line":3}},"version":0},{"kind":"test","payload":{"_parameters":[{"name":"value","typeName":"Swift.String"}],"_testCases":[{"displayName":"\"a\"","id":"Parameterized test case ID: argumentIDs: [Testing.Test.Case.Argument.ID(bytes: [172, 141, 131, 66, 187, 178, 54, 45, 19, 240, 165, 89, 163, 98, 27, 180, 7, 1, 19, 104, 137, 81, 100, 182, 40, 165, 79, 127, 195, 63, 196, 60])], discriminator: 0, isStable: true"},{"displayName":"\"b\"","id":"Parameterized test case ID: argumentIDs: [Testing.Test.Case.Argument.ID(bytes: [193, 0, 249, 92, 25, 19, 249, 199, 47, 193, 244, 239, 8, 71, 225, 231, 35, 255, 224, 189, 224, 179, 110, 95, 54, 193, 63, 129, 254, 140, 38, 237])], discriminator: 0, isStable: true"}],"id":"ProbeTests.SampleSuite/parameter(value:)/ProbeTests.swift:5:3","isParameterized":true,"kind":"function","name":"parameter(value:)","sourceLocation":{"_filePath":"/private/tmp/throttle-vault-schema-probe-xanw33lr/Tests/ProbeTests/ProbeTests.swift","column":3,"fileID":"ProbeTests/ProbeTests.swift","line":5}},"version":0},{"kind":"test","payload":{"displayName":"Pretty plain","id":"ProbeTests.SampleSuite/plain()/ProbeTests.swift:4:3","isParameterized":false,"kind":"function","name":"plain()","sourceLocation":{"_filePath":"/private/tmp/throttle-vault-schema-probe-xanw33lr/Tests/ProbeTests/ProbeTests.swift","column":3,"fileID":"ProbeTests/ProbeTests.swift","line":4}},"version":0},{"kind":"event","payload":{"instant":{"absolute":287750.619208291,"since1970":1788885596.297439},"kind":"runStarted","messages":[{"symbol":"default","text":"Test run started."},{"symbol":"details","text":"Testing Library Version: 2078"},{"symbol":"details","text":"Target Platform: arm64e-apple-macos14.0"}]},"version":0},{"kind":"event","payload":{"instant":{"absolute":287750.619391791,"since1970":1788885596.297622},"kind":"testStarted","messages":[{"symbol":"default","text":"Suite SampleSuite started."}],"testID":"ProbeTests.SampleSuite"},"version":0},{"kind":"event","payload":{"instant":{"absolute":287750.61948887503,"since1970":1788885596.297719},"kind":"testStarted","messages":[{"symbol":"default","text":"Test parameter(value:) started."}],"testID":"ProbeTests.SampleSuite/parameter(value:)/ProbeTests.swift:5:3"},"version":0},{"kind":"event","payload":{"instant":{"absolute":287750.619536333,"since1970":1788885596.297766},"kind":"testStarted","messages":[],"testID":"ProbeTests.SampleSuite/plain()/ProbeTests.swift:4:3"},"version":0},{"kind":"event","payload":{"_testCase":{"displayName":"\"b\"","id":"Parameterized test case ID: argumentIDs: [Testing.Test.Case.Argument.ID(bytes: [193, 0, 249, 92, 25, 19, 249, 199, 47, 193, 244, 239, 8, 71, 225, 231, 35, 255, 224, 189, 224, 179, 110, 95, 54, 193, 63, 129, 254, 140, 38, 237])], discriminator: 0, isStable: true"},"instant":{"absolute":287750.61956604104,"since1970":1788885596.2977958},"kind":"testCaseStarted","messages":[{"symbol":"default","text":"Test case passing 1 argument value \u2192 \"b\" to parameter(value:) started."}],"testID":"ProbeTests.SampleSuite/parameter(value:)/ProbeTests.swift:5:3"},"version":0},{"kind":"event","payload":{"instant":{"absolute":287750.6196235,"since1970":1788885596.297854},"kind":"testEnded","messages":[],"testID":"ProbeTests.SampleSuite/plain()/ProbeTests.swift:4:3"},"version":0},{"kind":"event","payload":{"_testCase":{"displayName":"\"a\"","id":"Parameterized test case ID: argumentIDs: [Testing.Test.Case.Argument.ID(bytes: [172, 141, 131, 66, 187, 178, 54, 45, 19, 240, 165, 89, 163, 98, 27, 180, 7, 1, 19, 104, 137, 81, 100, 182, 40, 165, 79, 127, 195, 63, 196, 60])], discriminator: 0, isStable: true"},"instant":{"absolute":287750.61956125003,"since1970":1788885596.297791},"kind":"testCaseStarted","messages":[{"symbol":"default","text":"Test case passing 1 argument value \u2192 \"a\" to parameter(value:) started."}],"testID":"ProbeTests.SampleSuite/parameter(value:)/ProbeTests.swift:5:3"},"version":0},{"kind":"event","payload":{"_testCase":{"displayName":"\"b\"","id":"Parameterized test case ID: argumentIDs: [Testing.Test.Case.Argument.ID(bytes: [193, 0, 249, 92, 25, 19, 249, 199, 47, 193, 244, 239, 8, 71, 225, 231, 35, 255, 224, 189, 224, 179, 110, 95, 54, 193, 63, 129, 254, 140, 38, 237])], discriminator: 0, isStable: true"},"instant":{"absolute":287750.61965625,"since1970":1788885596.2978861},"kind":"testCaseEnded","messages":[],"testID":"ProbeTests.SampleSuite/parameter(value:)/ProbeTests.swift:5:3"},"version":0},{"kind":"event","payload":{"_testCase":{"displayName":"\"a\"","id":"Parameterized test case ID: argumentIDs: [Testing.Test.Case.Argument.ID(bytes: [172, 141, 131, 66, 187, 178, 54, 45, 19, 240, 165, 89, 163, 98, 27, 180, 7, 1, 19, 104, 137, 81, 100, 182, 40, 165, 79, 127, 195, 63, 196, 60])], discriminator: 0, isStable: true"},"instant":{"absolute":287750.619703708,"since1970":1788885596.297934},"kind":"testCaseEnded","messages":[],"testID":"ProbeTests.SampleSuite/parameter(value:)/ProbeTests.swift:5:3"},"version":0},{"kind":"event","payload":{"instant":{"absolute":287750.619751083,"since1970":1788885596.297981},"kind":"testEnded","messages":[{"symbol":"pass","text":"Test parameter(value:) with 2 test cases passed after 0.001 seconds."}],"testID":"ProbeTests.SampleSuite/parameter(value:)/ProbeTests.swift:5:3"},"version":0},{"kind":"event","payload":{"instant":{"absolute":287750.619800958,"since1970":1788885596.2980309},"kind":"testEnded","messages":[{"symbol":"pass","text":"Suite SampleSuite passed after 0.001 seconds."}],"testID":"ProbeTests.SampleSuite"},"version":0},{"kind":"event","payload":{"instant":{"absolute":287750.619839791,"since1970":1788885596.29807},"kind":"runEnded","messages":[{"symbol":"pass","text":"Test run with 2 tests in 1 suite passed after 0.001 seconds."}]},"version":0}]''')


if __name__ == "__main__":
    unittest.main()
