"""Execute the actual release CI assertion block against isolated file fixtures.

The build/release scripts are never run. Bash syntax and grep assertions are
real; unrelated node/Python validations are stubs. No signing or upload occurs.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/ci.yml"


def release_gate_block(workflow):
    step = re.search(
        r"^      - name: Enforce fail-closed release scripts\n        run: \|\n((?:          .*\n|\n)+)",
        workflow, re.MULTILINE)
    if step is None:
        raise AssertionError("The release CI assertion block is missing or has an unsupported shape")
    return "\n".join(line[10:] for line in step.group(1).splitlines() if line)


class ReleaseCIGateTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="throttle-release-ci-gates-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        self.release_scripts = ("build-dmg.sh", "finalize-dmg.sh", "smoke-test.sh", "verify-public-release.sh")
        for filename in self.release_scripts:
            (self.scripts / filename).write_text(
                '#!/bin/bash\nNOTARIZE=false\ncase "${1:-}" in\n'
                '  --notarize) NOTARIZE=true;;\nesac\n')
        shutil.copyfile(ROOT / "scripts/assert-no-match.sh", self.scripts / "assert-no-match.sh")
        (self.scripts / "stage-release.py").write_text('SITE = "https://lorislab.fr/throttle"\n')
        (self.scripts / "publish-release.mjs").write_text('// deploy-stamp.txt\n')
        listing = self.root / "design/appstore"
        listing.mkdir(parents=True)
        (listing / "listing.md").write_text("same local network\n")
        (listing / "make-screenshots.py").write_text("# local fixture\n")
        tools = self.root / "tools"
        tools.mkdir()
        for name in ("bash", "sh", "grep"):
            self.assertIsNotNone(path := shutil.which(name), f"Fixture prerequisite missing: {name}")
            (tools / name).symlink_to(path)
        for name in ("node", "python3"):
            path = tools / name
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(tools))
        self.block = release_gate_block(WORKFLOW.read_text())

    def run_gate(self):
        return subprocess.run(["/bin/bash", "-e", "-c", self.block], cwd=self.root,
                              env=self.environment, capture_output=True, text=True, timeout=10)

    def assert_refused(self):
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_valid_fixture_passes_the_actual_ci_block(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_syntax_error_in_each_release_script_is_rejected(self):
        for filename in self.release_scripts:
            with self.subTest(script=filename):
                path = self.scripts / filename
                original = path.read_text()
                path.write_text("if then\n" + original)
                try:
                    self.assert_refused()
                finally:
                    path.write_text(original)

    def test_each_notarization_script_must_default_to_disabled(self):
        for filename in ("build-dmg.sh", "finalize-dmg.sh"):
            with self.subTest(script=filename):
                path = self.scripts / filename
                original = path.read_text()
                path.write_text(original.replace("NOTARIZE=false", "NOTARIZE=true"))
                try:
                    self.assert_refused()
                finally:
                    path.write_text(original)

    def test_each_notarization_script_must_have_the_explicit_flag(self):
        for filename in ("build-dmg.sh", "finalize-dmg.sh"):
            with self.subTest(script=filename):
                path = self.scripts / filename
                original = path.read_text()
                path.write_text("#!/bin/bash\nNOTARIZE=false\n")
                try:
                    self.assert_refused()
                finally:
                    path.write_text(original)


if __name__ == "__main__":
    unittest.main()
