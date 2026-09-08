"""Run the Vault shell gates with public local fixtures and stub build products.

No Swift build, oracle, application, account or private repository is invoked.
"""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[2] / "Packages/ResearchVaultKit/Scripts"


class VaultScriptGateFixture(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="throttle-script-gates-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.package = self.root / "package"
        self.package.mkdir()
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.temporary = self.root / "temporary"
        self.temporary.mkdir()
        self.products = self.root / "products"
        self.products.mkdir()
        self.environment = dict(os.environ, PATH=str(self.tools), TMPDIR=str(self.temporary),
                                FIXTURE_PRODUCTS=str(self.products))
        self.environment.pop("RESEARCH_VAULT_APP_BUNDLE", None)
        for name in ("sh", "dirname", "grep", "find", "mktemp", "mkdir", "rm", "rmdir",
                     "sort", "xargs", "shasum", "mv", "wc", "tr", "cp"):
            self.assertIsNotNone(path := shutil.which(name), f"Fixture prerequisite missing: {name}")
            (self.tools / name).symlink_to(path)

    def tool(self, name, body):
        path = self.tools / name
        if path.exists() or path.is_symlink():
            path.unlink()
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)
        return path

    def copy_script(self, name):
        path = self.package / "Scripts" / name
        path.parent.mkdir(exist_ok=True)
        shutil.copyfile(SCRIPTS / name, path)
        return path

    def run_gate(self, script, *arguments):
        return subprocess.run(["/bin/sh", str(script), *map(str, arguments)], cwd=self.package,
                              env=self.environment, capture_output=True, text=True, timeout=10)

    def assert_refused(self, result, diagnostic=None):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('"status":"pass"', result.stdout)
        self.assertNotIn("PACKAGED:", result.stdout)
        if diagnostic is not None:
            self.assertIn(diagnostic, result.stderr)

    def stub_build(self):
        self.tool("swift", 'case "$*" in\n*--show-bin-path*) printf "%s\\n" "$FIXTURE_PRODUCTS";;\n*) exit 0;;\nesac\n')


class ReasoningSupplyChainGateTests(VaultScriptGateFixture):
    def setUp(self):
        super().setUp()
        self.script = self.copy_script("verify-reasoning-supply-chain.sh")
        self.manifest = self.package / "Package.swift"
        self.lock = self.package / "Package.resolved"
        self.manifest.write_text("import PackageDescription\n")
        self.lock.write_text('{"pins":[]}\n')
        self.bundle = self.root / "Application.app"
        self.bundle.mkdir()

    def test_graph_only_success_does_not_claim_bundle_inspection(self):
        result = self.run_gate(self.script)
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertTrue(receipt["package_graph_verified"])
        self.assertIs(receipt["bundle_filename_scan_performed"], False)

    def test_explicit_bundle_is_actually_scanned(self):
        self.environment["RESEARCH_VAULT_APP_BUNDLE"] = str(self.bundle)
        result = self.run_gate(self.script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIs(json.loads(result.stdout)["bundle_filename_scan_performed"], True)
        (self.bundle / "LeMmAlOg.framework").mkdir()
        self.assert_refused(self.run_gate(self.script), "appears in the application bundle")

    def test_each_graph_input_rejects_oracle_dependency(self):
        for path in (self.manifest, self.lock):
            for value in ("LeMmAlOg", "grahambrooks"):
                with self.subTest(file=path.name, value=value):
                    previous = path.read_text()
                    path.write_text(value)
                    self.assert_refused(self.run_gate(self.script), "appears in the Swift package graph")
                    path.write_text(previous)

    def test_bundle_symlink_cannot_turn_the_contents_scan_into_an_empty_scan(self):
        alias = self.root / "Alias.app"
        alias.symlink_to(self.bundle, target_is_directory=True)
        self.environment["RESEARCH_VAULT_APP_BUNDLE"] = str(alias)
        (self.bundle / "lemmalog.runtime").write_text("fixture oracle")
        self.assert_refused(self.run_gate(self.script), "appears in the application bundle")

    def test_missing_graph_input_or_explicit_bundle_fails(self):
        self.lock.unlink()
        self.assert_refused(self.run_gate(self.script), "Package graph input missing")
        self.lock.write_text("{}")
        self.environment["RESEARCH_VAULT_APP_BUNDLE"] = str(self.root / "missing.app")
        self.assert_refused(self.run_gate(self.script), "bundle directory missing")

    def test_missing_grep_or_find_is_not_absence(self):
        for name in ("grep", "find"):
            with self.subTest(tool=name):
                path = self.tools / name
                original = path.readlink()
                path.unlink()
                self.assert_refused(self.run_gate(self.script), "prerequisite missing: " + name)
                path.symlink_to(original)

    def test_grep_errors_are_not_absence(self):
        for status in (2, 126, 127):
            with self.subTest(status=status):
                self.tool("grep", f'exit {status}\n')
                self.assert_refused(self.run_gate(self.script), f"grep failed (status {status})")

    def test_real_grep_io_failure_is_rejected(self):
        grep = shlex.quote(str((self.tools / "grep").resolve()))
        self.tool("grep", f'exec {grep} -Ei "$2" "$3.disappeared"\n')
        self.assert_refused(self.run_gate(self.script), "grep failed (status 2)")

    def test_find_error_with_empty_or_partial_output_fails(self):
        self.environment["RESEARCH_VAULT_APP_BUNDLE"] = str(self.bundle)
        for output in ("", "partial-innocent-path"):
            with self.subTest(output=output):
                self.tool("find", f'printf "%s" {shlex.quote(output)}\nexit 2\n')
                self.assert_refused(self.run_gate(self.script), "bundle traversal failed")


class MCPPackageGateTests(VaultScriptGateFixture):
    def setUp(self):
        super().setUp()
        self.script = self.copy_script("package-mcp-helper.sh")
        self.stub_build()
        self.tool("otool", 'printf "@rpath/SQLCipher.framework/Versions/A/SQLCipher\\n"\n')
        self.tool("ditto", 'exec cp -R "$1" "$2"\n')
        binary = self.products / "research-vault-mcp"
        binary.write_text("synthetic binary fixture")
        binary.chmod(0o755)
        framework = self.products / "SQLCipher.framework"
        framework.mkdir()
        (framework / "SQLCipher").write_text("synthetic SQLCipher fixture")
        (self.package / "THIRD_PARTY_NOTICES.md").write_text("fixture notice")
        (self.package / "README.md").write_text("fixture readme")
        self.destination = self.root / "destination"

    def run_package(self):
        return self.run_gate(self.script, self.destination)

    def test_complete_fixture_creates_manifest_and_reports_success(self):
        result = self.run_package()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PACKAGED:", result.stdout)
        lines = (self.destination / "SHA256SUMS").read_text().splitlines()
        self.assertEqual(len(lines), 4)
        self.assertTrue(any("SQLCipher.framework/SQLCipher" in line for line in lines))
        self.assertEqual(list(self.temporary.iterdir()), [])

    def test_partial_otool_output_with_error_is_rejected(self):
        self.tool("otool", 'printf "@rpath/SQLCipher.framework/Versions/A/SQLCipher\\n"\nexit 2\n')
        self.assert_refused(self.run_package(), "otool could not inspect")
        self.assertFalse(self.destination.exists())

    def test_missing_otool_is_rejected(self):
        (self.tools / "otool").unlink()
        self.assert_refused(self.run_package(), "otool is missing")

    def test_system_sqlite_or_missing_sqlcipher_is_rejected(self):
        for libraries, diagnostic in (("/usr/lib/libsqlite3.dylib\n@rpath/SQLCipher.framework", "links system SQLite"),
                                      ("/usr/lib/libSystem.B.dylib", "SQLCipher linkage is missing")):
            with self.subTest(libraries=libraries):
                self.tool("otool", f'printf "%s\\n" {shlex.quote(libraries)}\n')
                self.assert_refused(self.run_package(), diagnostic)

    def test_partial_find_manifest_cannot_be_packaged(self):
        self.tool("find", 'printf "./README.md\\0"\nexit 2\n')
        self.assert_refused(self.run_package())
        self.assertFalse(self.destination.exists())

    def test_partial_sort_manifest_cannot_be_packaged(self):
        self.tool("sort", 'printf "./README.md\\0"\nexit 2\n')
        self.assert_refused(self.run_package())
        self.assertFalse(self.destination.exists())

    def test_hash_failure_or_missing_find_cannot_be_packaged(self):
        self.tool("shasum", 'printf "partial digest\\n"\nexit 2\n')
        self.assert_refused(self.run_package())
        self.assertFalse(self.destination.exists())
        (self.tools / "find").unlink()
        self.assert_refused(self.run_package())
        self.assertFalse(self.destination.exists())


class AgentHookGateTests(VaultScriptGateFixture):
    def setUp(self):
        super().setUp()
        self.script = self.copy_script("verify-agent-hook.sh")
        self.stub_build()
        # This fixture isolates the shell's traversal check; jq/application
        # semantics are covered elsewhere and are not claimed by these tests.
        self.tool("jq", 'case "$*" in\n*-cn*) printf "{\\"status\\":\\"pass\\"}\\n";;\n*-r*) printf "fixture-id\\n";;\n*) exit 0;;\nesac\n')
        hook = self.products / "research-vault-agent-hook"
        hook.write_text('#!/bin/sh\nprintf "{}\\n" > "$2/fixture.research-receipt.json"\nprintf "{}\\n"\n')
        hook.chmod(0o755)

    def test_one_receipt_fixture_reaches_idempotence_report(self):
        result = self.run_gate(self.script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "pass")

    def test_find_partial_one_file_then_error_is_not_idempotence(self):
        self.tool("find", 'printf "partial.research-receipt.json\\n"\nexit 2\n')
        self.assert_refused(self.run_gate(self.script))

    def test_missing_find_or_failed_counter_cannot_pass(self):
        self.tool("wc", 'printf "1\\n"\nexit 2\n')
        self.assert_refused(self.run_gate(self.script))
        (self.tools / "find").unlink()
        self.assert_refused(self.run_gate(self.script))


if __name__ == "__main__":
    unittest.main()
