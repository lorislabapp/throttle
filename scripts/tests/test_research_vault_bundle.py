"""Exercise the real bundle checker with simulated codesign/otool observations.

PlistBuddy reads real local fixture plists. No real code signing, application,
Keychain, service or network is used; success here is checker control-flow proof.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "verify-research-vault-bundle.sh"


class ResearchVaultBundleGateTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="throttle-bundle-checker-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.app = self.root / "Throttle.app"
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.agent = self.app / "Contents/Library/LoginItems/ResearchVaultAgent.app"
        self.sparkle = self.app / "Contents/Frameworks/Sparkle.framework/Versions/B"
        for path in (self.app / "Contents/MacOS/Throttle", self.agent / "Contents/MacOS/ResearchVaultAgent",
                     self.agent / "Contents/Frameworks/SQLCipher.framework/Versions/A/SQLCipher",
                     self.sparkle / "Autoupdate"):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("synthetic fixture, not executable application code")
            path.chmod(0o755)
        for path in (self.sparkle / "Updater.app", self.sparkle / "XPCServices/Downloader.xpc",
                     self.sparkle / "XPCServices/Installer.xpc"):
            path.mkdir(parents=True)
        self.launch = self.app / "Contents/Library/LaunchAgents/com.lorislab.throttle.research-vault-agent.plist"
        self.launch.parent.mkdir(parents=True)
        self.launch.write_bytes(plistlib.dumps({
            "Label": "com.lorislab.throttle.research-vault-agent",
            "BundleProgram": "Contents/Library/LoginItems/ResearchVaultAgent.app/Contents/MacOS/ResearchVaultAgent",
            "MachServices": {"com.lorislab.throttle.research-vault." + service: True
                             for service in ("query.cheatcode", "query.throttle", "owner.throttle")}}))
        for name in ("plutil", "grep", "sed"):
            self.assertIsNotNone(path := shutil.which(name), f"Fixture prerequisite missing: {name}")
            (self.tools / name).symlink_to(path)
        self.tool("otool", 'case "$2" in\n*ResearchVaultAgent) printf "@rpath/SQLCipher.framework/Versions/A/SQLCipher\\n";;\n*) printf "/usr/lib/libSystem.B.dylib\\n";;\nesac\n')
        self.tool("codesign", CODESIGN_FIXTURE)
        self.environment = dict(os.environ, PATH=str(self.tools), FAIL_KIND="", SIGNING_MUTATION="")

    def tool(self, name, body):
        path = self.tools / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def run_gate(self, signed=True):
        arguments = ["/bin/sh", str(SCRIPT)]
        if signed:
            arguments.append("--require-signed")
        return subprocess.run([*arguments, str(self.app)], env=self.environment,
                              capture_output=True, text=True, timeout=15)

    def assert_refused(self, diagnostic=None):
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('"status":"pass"', result.stdout)
        if diagnostic:
            self.assertIn(diagnostic, result.stderr)

    def test_successful_stub_observations_pass_the_unchanged_signature_policy(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "status": "pass", "scenario": "research-vault-bundle", "signed": 1})

    def test_structural_mode_does_not_invoke_or_claim_signature_verification(self):
        (self.tools / "codesign").unlink()
        result = self.run_gate(signed=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["signed"], 0)

    def test_missing_codesign_cannot_qualify_a_signed_bundle(self):
        (self.tools / "codesign").unlink()
        self.assert_refused()

    def test_failed_deep_verification_cannot_qualify_a_signed_bundle(self):
        self.environment["FAIL_KIND"] = "verify"
        self.assert_refused()

    def test_failed_main_or_agent_metadata_is_rejected_even_with_valid_output(self):
        for kind in ("main", "agent"):
            with self.subTest(observation=kind):
                self.environment["FAIL_KIND"] = kind
                self.assert_refused("codesign inspection failed")

    def test_failed_entitlements_are_rejected_even_with_valid_plist_output(self):
        self.environment["FAIL_KIND"] = "entitlements"
        self.assert_refused("codesign inspection failed")

    def test_failed_entitlements_without_output_are_not_evidence_of_absence(self):
        self.environment["FAIL_KIND"] = "entitlements"
        self.environment["SIGNING_MUTATION"] = "empty-entitlements"
        self.assert_refused("codesign inspection failed")

    def test_failed_nested_observation_is_rejected_even_with_valid_team_and_timestamp(self):
        for nested in ("Updater.app", "Autoupdate", "Downloader.xpc", "Installer.xpc"):
            with self.subTest(observation=nested):
                self.environment["FAIL_KIND"] = nested
                self.assert_refused("codesign inspection failed")

    def test_existing_identifier_team_entitlement_and_timestamp_policies_still_reject(self):
        for mutation, diagnostic in (("main-identifier", "unexpected Throttle signing identifier"),
                                     ("agent-identifier", "unexpected agent signing identifier"),
                                     ("main-team", "unexpected Throttle Team ID"),
                                     ("agent-team", "unexpected agent Team ID"),
                                     ("get-task-allow", "forbidden get-task-allow"),
                                     ("nested-team", "unexpected nested Team ID"),
                                     ("missing-timestamp", "missing secure timestamp")):
            with self.subTest(mutation=mutation):
                self.environment["SIGNING_MUTATION"] = mutation
                self.assert_refused(diagnostic)


CODESIGN_FIXTURE = r'''
for last do :; done
case "$1" in
    --verify)
        if [ "$FAIL_KIND" = verify ]; then printf "valid-looking partial verification\n"; exit 2; fi
        exit 0 ;;
esac
case "$*" in
    *--entitlements*)
        if [ "$SIGNING_MUTATION" != empty-entitlements ]; then
            if [ "$SIGNING_MUTATION" = get-task-allow ]; then
                printf '<plist><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>\n'
            else
                printf '<plist><dict/></plist>\n'
            fi
        fi
        if [ "$FAIL_KIND" = entitlements ]; then exit 2; fi
        exit 0 ;;
esac
identifier=com.lorislab.throttle
team=TDV6D5L785
case "$last" in
    *ResearchVaultAgent.app) kind=agent; identifier=com.lorislab.throttle.research-vault-agent ;;
    *Throttle.app) kind=main ;;
    *) kind=${last##*/} ;;
esac
if [ "$SIGNING_MUTATION" = "$kind-identifier" ]; then identifier=wrong.identifier; fi
if [ "$SIGNING_MUTATION" = "$kind-team" ]; then team=WRONGTEAM; fi
if [ "$SIGNING_MUTATION" = nested-team ] && [ "$1" = -dvvv ]; then team=WRONGTEAM; fi
printf 'Identifier=%s\nTeamIdentifier=%s\n' "$identifier" "$team" >&2
if [ "$SIGNING_MUTATION" != missing-timestamp ]; then printf 'Timestamp=synthetic-fixture\n' >&2; fi
if [ "$FAIL_KIND" = "$kind" ]; then exit 2; fi
exit 0
'''


if __name__ == "__main__":
    unittest.main()
