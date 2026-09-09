import csv
import importlib.util
import io
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("pilot_metrics", ROOT / "scripts/pilot-metrics.py")
pilot = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pilot)


def registry(rows):
    buffer = io.StringIO()
    writer = csv.DictWriter(buffer, fieldnames=pilot.COLUMNS)
    writer.writeheader()
    for index in range(10):
        row = {column: "" for column in pilot.COLUMNS}
        row.update({"slot": str(index + 1), "status": "pending"})
        row.update(rows.get(index + 1, {}))
        writer.writerow(row)
    return buffer.getvalue()


def measured(slot, **overrides):
    row = {"status": "measured", "project": "Throttle", "task": "t", "acceptance_criterion": "c",
           "source_snapshot": "abc", "context_variant": "v1", "model_versions": "m", "evidence_path": "e.md",
           "attempts": "1", "total_cost_eur": "2.5", "human_minutes": "30", "elapsed_minutes": "60",
           "accepted": "yes", "regressions": "0"}
    row.update(overrides)
    return {slot: row}


class PilotMetricsTests(unittest.TestCase):
    def load(self, text):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "pilot.csv"
            path.write_text(text)
            return pilot.load(path)

    def test_the_committed_registry_is_valid_and_makes_no_claim(self):
        report = pilot.metrics(pilot.load(ROOT / "docs/testing/pilot-10-tasks.csv"))
        self.assertEqual(report["measured"], 0)
        self.assertIsNone(report["acceptance_rate"])
        self.assertFalse(report["instrumentation_verified"])
        self.assertIn("no productivity claim", report["claim"])

    def test_measured_rows_aggregate_without_inventing_costs(self):
        rows = {}
        rows.update(measured(1))
        rows.update(measured(2, accepted="no", total_cost_eur="4", human_minutes="10"))
        rows.update(measured(3, regressions="1", total_cost_eur="1.5"))
        report = pilot.metrics(self.load(registry(rows)))
        self.assertEqual((report["measured"], report["accepted"]), (3, 2))
        self.assertAlmostEqual(report["acceptance_rate"], 2 / 3)
        self.assertAlmostEqual(report["cost_eur_per_accepted"], (2.5 + 4 + 1.5) / 2)
        self.assertAlmostEqual(report["human_minutes_per_accepted"], (30 + 10 + 30) / 2)
        self.assertEqual(report["regressions_after_acceptance"], 1)
        self.assertFalse(report["instrumentation_verified"])

    def test_ten_measured_rows_verify_the_instrumentation_only(self):
        rows = {}
        for slot in range(1, 11):
            rows.update(measured(slot))
        report = pilot.metrics(self.load(registry(rows)))
        self.assertTrue(report["instrumentation_verified"])
        self.assertIn("compare variants", report["claim"])

    def test_incomplete_or_invented_measurements_are_refused(self):
        for overrides in ({"total_cost_eur": ""}, {"human_minutes": "unknown"}, {"evidence_path": ""},
                          {"accepted": "maybe"}, {"attempts": "0"}, {"regressions": "-1"}):
            with self.assertRaises(pilot.RegistryError, msg=str(overrides)):
                self.load(registry(measured(1, **overrides)))
        with self.assertRaises(pilot.RegistryError):
            self.load(registry({2: {"status": "pending", "total_cost_eur": "0"}}))
        with self.assertRaises(pilot.RegistryError):
            self.load(registry({2: {"status": "done"}}))
        with self.assertRaises(pilot.RegistryError):
            self.load(registry(rows={}).replace("\n10,pending", "\n1,pending"))


if __name__ == "__main__":
    unittest.main()
