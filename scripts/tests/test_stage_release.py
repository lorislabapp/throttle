"""Release gate failures preserve staging; Ed25519 uses an RFC 8032 vector.

The DMG/ticket are synthetic. These tests prove the signature and refusal paths,
not notarization or a Sparkle update. No Keychain, account or network is accessed.
"""
import base64
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "stage_release", Path(__file__).resolve().parents[1] / "stage-release.py")
stage_release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(stage_release)
RUN = subprocess.run

# RFC 8032 section 7.1, TEST 2: message 0x72. Only public verification data.
# https://www.rfc-editor.org/rfc/rfc8032#section-7.1
PUBLIC_KEY = base64.b64encode(bytes.fromhex(
    "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")).decode()
SIGNATURE = base64.b64encode(bytes.fromhex(
    "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
    "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00")).decode()


class StageReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="throttle-stage-fixture-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.dmg = self.root / "Throttle-0.0.0.dmg"
        self.dmg.write_bytes(b"\x72")
        self.info = self.root / "export/Throttle.app/Contents/Info.plist"
        self.info.parent.mkdir(parents=True)
        self.metadata = {"CFBundleIdentifier": "com.lorislab.throttle",
                         "CFBundleShortVersionString": "0.0.0", "CFBundleVersion": "999",
                         "SUPublicEDKey": PUBLIC_KEY}
        self.write_metadata()
        self.project = self.root / "project.yml"
        self.project.write_text(f'SUPublicEDKey: "{PUBLIC_KEY}"\n')
        self.signature = SIGNATURE
        self.entry = self.root / "appcast-entry-0.0.0.xml"
        self.live = self.root / "live.xml"
        self.live.write_text('<channel>\n        <language>en</language>\n</channel>\n')
        self.page = self.root / "page.html"
        self.page.write_text('<a href="Throttle-0.0.1.dmg">Download</a>'
                             '<span class="mono">v0.0.1</span> · 0.1 MB')
        self.stage = self.root / "stage"
        self.stage.mkdir()
        self.sentinel = self.stage / "prior-candidate.txt"
        self.sentinel.write_text("preserve until verification succeeds")
        self.patch_project = patch.object(stage_release, "PROJECT_YML", str(self.project))
        self.patch_project.start()
        self.addCleanup(self.patch_project.stop)

    def write_metadata(self):
        self.info.write_bytes(plistlib.dumps(self.metadata))

    def run_stage(self, verifier=None):
        self.entry.write_text('<item><sparkle:version>999</sparkle:version>'
                              '<pubDate>Tue, 08 Sep 2026 12:00:00 +0000</pubDate>'
                              f'<enclosure sparkle:edSignature="{self.signature}" length="1" /></item>')

        def run(args, **kwargs):
            if args[:3] == ["xcrun", "stapler", "validate"]:
                return subprocess.CompletedProcess(args, 0)  # Ticket fixture only.
            self.assertEqual(args[:3], ["/usr/bin/xcrun", "swift", "-e"])
            return verifier(args, **kwargs) if verifier else RUN(args, **kwargs)

        argv = ["stage-release.py", "--version", "0.0.0", "--build-dir", str(self.root),
                "--stage", str(self.stage), "--live-appcast", str(self.live),
                "--live-page", str(self.page)]
        with patch.object(sys, "argv", argv), patch.object(stage_release.subprocess, "run", side_effect=run):
            stage_release.main()

    def assert_refused(self, expected, verifier=None):
        with self.assertRaisesRegex(SystemExit, expected):
            self.run_stage(verifier)
        self.assertEqual(self.sentinel.read_text(), "preserve until verification succeeds")
        self.assertFalse((self.stage / "throttle").exists())

    def test_real_ed25519_signature_stages_exact_bytes(self):
        self.stage = self.root / "fresh-stage"
        self.run_stage()
        self.assertEqual((self.stage / "throttle/Throttle-0.0.0.dmg").read_bytes(), b"\x72")
        self.assertIn(SIGNATURE, (self.stage / "throttle/appcast.xml").read_text())

    def test_verified_candidate_never_replaces_existing_stage(self):
        self.assert_refused("stage already exists")

    def test_stage_symlink_cannot_delete_exported_app(self):
        self.stage = self.root / "stage-link"
        self.stage.symlink_to(self.root / "export", target_is_directory=True)
        self.assert_refused("stage already exists")
        self.assertEqual(plistlib.loads(self.info.read_bytes()), self.metadata)

    def test_stage_file_is_preserved(self):
        self.stage = self.root / "existing-stage-file"
        self.stage.write_text("existing user file")
        self.assert_refused("stage already exists")
        self.assertEqual(self.stage.read_text(), "existing user file")

    def test_source_changed_after_verification_cannot_form_publishable_stage(self):
        self.stage = self.root / "changed-source-stage"

        def change_source_after_verification(args, **kwargs):
            result = RUN(args, **kwargs)
            if json.loads(kwargs["input"])["path"] == str(self.dmg):
                self.dmg.write_bytes(b"\x73")
            return result

        with self.assertRaisesRegex(SystemExit, "Ed25519 verification failed"):
            self.run_stage(change_source_after_verification)
        self.assertFalse((self.stage / "throttle/appcast.xml").exists())
        self.assertFalse((self.stage / "throttle/index.html").exists())

    def test_same_size_corrupt_dmg_is_refused(self):
        self.dmg.write_bytes(b"\x73")
        self.assert_refused("Ed25519 verification failed")

    def test_valid_signature_for_another_public_key_is_refused(self):
        other = base64.b64encode(bytes.fromhex(
            "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")).decode()
        self.metadata["SUPublicEDKey"] = other
        self.write_metadata()
        self.project.write_text(f'SUPublicEDKey: "{other}"\n')
        self.assert_refused("Ed25519 verification failed")

    def test_app_and_project_key_mismatch_is_refused(self):
        self.metadata["SUPublicEDKey"] = base64.b64encode(bytes(32)).decode()
        self.write_metadata()
        self.assert_refused("does not match the project's release key")

    def test_missing_exported_metadata_is_refused(self):
        self.info.unlink()
        self.assert_refused("could not validate exported app metadata")

    def test_wrong_app_build_is_refused(self):
        self.metadata["CFBundleVersion"] = "998"
        self.write_metadata()
        self.assert_refused("identity/version/build does not match")

    def test_malformed_signature_is_refused(self):
        self.signature = "!invalid!"
        self.assert_refused("signature encoding")

    def test_missing_verifier_is_refused(self):
        def missing(*_args, **_kwargs):
            raise FileNotFoundError("synthetic unavailable verifier")
        self.assert_refused("verifier unavailable", missing)

    def test_timed_out_verifier_is_refused(self):
        def timeout(args, **_kwargs):
            raise subprocess.TimeoutExpired(args, 120)
        self.assert_refused("verifier unavailable or timed out", timeout)

    def test_zero_exit_without_verification_receipt_is_refused(self):
        self.assert_refused("Ed25519 verification failed",
                            lambda args, **_kwargs: subprocess.CompletedProcess(args, 0, "", ""))

    def test_failed_verifier_even_with_receipt_is_refused(self):
        self.assert_refused("Ed25519 verification failed", lambda args, **_kwargs:
                            subprocess.CompletedProcess(args, 1, "THROTTLE_ED25519_VALID\n", ""))


if __name__ == "__main__":
    unittest.main()
