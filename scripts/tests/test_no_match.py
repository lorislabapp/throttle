import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).parents[1] / "assert-no-match.sh"


class NoMatchTests(unittest.TestCase):
    def run_gate(self, *args, env=None):
        return subprocess.run(["/bin/sh", str(SCRIPT), *args], capture_output=True, text=True, env=env)

    def test_absence_passes_and_match_fails_without_echoing_content(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "input.txt"
            path.write_text("PRIVATE_FIXTURE_VALUE")
            self.assertEqual(self.run_gate("absent", str(path)).returncode, 0)
            result = self.run_gate("PRIVATE_FIXTURE_VALUE", str(path))
            self.assertEqual(result.returncode, 1)
            self.assertNotIn("PRIVATE_FIXTURE_VALUE", result.stdout + result.stderr)

    def test_missing_file_and_invalid_pattern_fail(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(self.run_gate("pattern", folder + "/missing").returncode, 2)
            self.assertEqual(self.run_gate("[", "/dev/null").returncode, 2)

    def test_missing_tool_fails(self):
        self.assertEqual(self.run_gate("pattern", "/dev/null", env={"PATH": "/nonexistent"}).returncode, 2)


if __name__ == "__main__":
    unittest.main()
