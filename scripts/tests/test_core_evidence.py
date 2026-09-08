"""Adversarial checks for the validator; no compiler or app is invoked."""
import importlib.util
import pathlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("core_evidence", pathlib.Path(__file__).parents[1] / "verify-core-evidence.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class EvidenceReportTests(unittest.TestCase):
    def check(self, xml, expected=None):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "results.xml"
            path.write_text(xml)
            return runner.validate_reports([path], expected or {"ExampleTests": ["test_one"]})[0]

    def test_complete_report_passes(self):
        self.assertEqual(self.check('<testsuite tests="1"><testcase classname="Module.ExampleTests" name="test_one"/></testsuite>'), [])

    def test_missing_suite_fails_even_with_another_green_suite(self):
        self.assertTrue(self.check('<testsuite><testcase classname="OtherTests" name="test_one"/></testsuite>'))

    def test_missing_case_fails(self):
        self.assertTrue(self.check('<testsuite><testcase classname="ExampleTests" name="test_one"/></testsuite>',
                                   {"ExampleTests": ["test_one", "test_two"]}))

    def test_empty_skipped_and_malformed_reports_fail(self):
        for xml in ['<testsuites/>', 'truncated xml', '<anything/>',
                    '<testsuite><testcase classname="ExampleTests" name="test_one"><skipped/></testcase></testsuite>']:
            with self.subTest(xml=xml):
                self.assertTrue(self.check(xml))

    def test_suite_level_errors_cannot_hide_behind_green_case(self):
        for attribute in ['failures="1"', 'errors="1"', 'errors="NaN"']:
            self.assertTrue(self.check(f'<testsuite {attribute}><testcase classname="ExampleTests" name="test_one"/></testsuite>'))

    def test_case_failures_and_duplicate_cases_fail(self):
        case = '<testcase classname="ExampleTests" name="test_one"/>'
        self.assertTrue(self.check('<testsuite>' + case + case + '</testsuite>'))
        for tag in ['failure', 'error']:
            self.assertTrue(self.check(f'<testsuite><testcase classname="ExampleTests" name="test_one"><{tag}/></testcase></testsuite>'))


if __name__ == "__main__":
    unittest.main()
