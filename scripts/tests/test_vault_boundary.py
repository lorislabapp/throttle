"""Exercise the real IPC boundary shell gate using isolated client/source fixtures."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "Packages/ResearchVaultKit/Scripts/verify-ipc-boundary.sh"


class VaultBoundaryTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="throttle-boundary-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.package = self.root / "vault package"
        self.script = self.package / "Scripts/verify-ipc-boundary.sh"
        self.script.parent.mkdir(parents=True)
        shutil.copyfile(SCRIPT, self.script)
        self.model = self.package / "Sources/ResearchVaultIPCModel/Request.swift"
        self.model.parent.mkdir(parents=True)
        self.model.write_text("import Foundation\nimport ResearchVaultModel\n")
        self.client = self.root / "client fixture"
        self.client_source = self.client / "Sources/Client/Query.swift"
        self.client_source.parent.mkdir(parents=True)
        self.client_source.write_text("import ResearchVaultXPCClient\nimport ResearchVaultIPCModel\n")
        self.manifest = self.client / "Package.swift"
        self.manifest.write_text("import PackageDescription\n")
        self.tools = self.root / "tools"
        self.tools.mkdir()
        for name in ("grep", "find", "sh", "dirname"):
            self.assertIsNotNone(path := shutil.which(name), f"Fixture prerequisite missing: {name}")
            (self.tools / name).symlink_to(path)
        self.environment = dict(os.environ, PATH=str(self.tools), RESEARCH_VAULT_CLIENT_ROOT=str(self.client))

    def run_gate(self):
        return subprocess.run(["/bin/sh", str(self.script)], cwd=self.root,
                              env=self.environment, capture_output=True, text=True, timeout=10)

    def assert_refused(self, diagnostic):
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(diagnostic, result.stderr)
        self.assertNotIn('"status":"pass"', result.stdout)
        return result

    def replace_tool(self, name, body):
        path = self.tools / name
        path.unlink()
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def test_clean_fixture_passes_without_ripgrep_or_external_repository(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "status": "pass", "scenario": "ipc-boundary-no-privileged-client-dependency"})
        self.assertEqual(result.stderr, "")

    def test_privileged_import_in_model_is_rejected(self):
        self.model.write_text("@testable import\tResearchVaultSQLCipher\n")
        self.assert_refused("IPC model imports a privileged")

    def test_owner_capabilities_are_rejected_without_echoing_source(self):
        for declaration in ("func importReceipts() {}", "func backup() {}", "func restore() {}",
                            "let databaseURL = PRIVATE_FIXTURE", "let databasePath = PRIVATE_FIXTURE",
                            "let masterKey = PRIVATE_FIXTURE"):
            with self.subTest(declaration=declaration):
                self.model.write_text(declaration)
                result = self.assert_refused("owner capability or grant")
                self.assertNotIn("PRIVATE_FIXTURE", result.stdout + result.stderr)

    def test_privileged_import_in_client_sources_or_manifest_is_rejected(self):
        for path in (self.client_source, self.manifest):
            for module in ("SQLCipher", "Gateway", "Keychain", "Ingestion", "Store", "MCP"):
                with self.subTest(path=path.name, module=module):
                    original = path.read_text()
                    path.write_text("import ResearchVault" + module + "\n")
                    self.assert_refused("Client directly imports a privileged")
                    path.write_text(original)

    def test_missing_grep_is_rejected_before_scanning(self):
        (self.tools / "grep").unlink()
        self.assert_refused("prerequisite missing: grep")

    def test_missing_find_is_rejected_before_scanning(self):
        (self.tools / "find").unlink()
        self.assert_refused("prerequisite missing: find")

    def test_missing_client_is_not_an_optional_skip(self):
        self.environment["RESEARCH_VAULT_CLIENT_ROOT"] = str(self.root / "missing client")
        self.assert_refused("Client Package.swift or Sources is missing")

    def test_empty_client_override_does_not_fall_back_to_real_checkout(self):
        self.environment["RESEARCH_VAULT_CLIENT_ROOT"] = ""
        self.assert_refused("Client Package.swift or Sources is missing")

    def test_missing_client_manifest_or_sources_is_rejected(self):
        self.manifest.unlink()
        self.assert_refused("Client Package.swift or Sources is missing")
        self.manifest.write_text("import PackageDescription\n")
        shutil.rmtree(self.client / "Sources")
        self.assert_refused("Client Package.swift or Sources is missing")

    def test_missing_model_is_rejected(self):
        shutil.rmtree(self.model.parent)
        self.assert_refused("IPC model source directory is missing")

    def test_grep_read_or_execution_error_cannot_mean_no_match(self):
        for status in (2, 126, 127):
            with self.subTest(status=status):
                self.replace_tool("grep", f'printf "synthetic read failure\\n" >&2\nexit {status}\n')
                self.assert_refused(f"grep failed (status {status})")

    def test_error_only_in_client_scan_cannot_be_hidden_by_clean_model(self):
        self.replace_tool("grep", 'case "$3" in\n*"client fixture"*) exit 2;;\n*) exit 1;;\nesac\n')
        self.assert_refused("grep failed (status 2)")

    def test_real_grep_read_error_is_not_absence(self):
        # Model a source disappearing between enumeration and the actual read.
        # The real installed grep emits the I/O failure; its status is not mocked.
        real_grep = shlex.quote(str((self.tools / "grep").resolve()))
        self.replace_tool("grep", f'exec {real_grep} -E "$2" "$3.disappeared"\n')
        self.assert_refused("grep failed (status 2)")

    def test_find_traversal_error_is_not_a_successful_scan(self):
        self.replace_tool("find", 'printf "synthetic traversal failure\\n" >&2\nexit 2\n')
        self.assert_refused("scan did not complete successfully")

    def test_symlink_cannot_hide_an_unscanned_source(self):
        for path in (self.model, self.client_source):
            with self.subTest(path=path.name):
                original = path.read_text()
                path.unlink()
                path.symlink_to(self.root / "absent target")
                self.assert_refused("cannot verify a symbolic link")
                path.unlink()
                path.write_text(original)


if __name__ == "__main__":
    unittest.main()
