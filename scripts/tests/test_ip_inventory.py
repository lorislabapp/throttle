"""Tests for the factual, fail-closed IP inventory."""

import importlib.util
import json
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    "ip_inventory", pathlib.Path(__file__).parents[1] / "ip-inventory.py"
)
inventory = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(inventory)


class IPInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")
        (self.root / "LICENSE").write_text("MIT License\n")
        (self.root / "README.md").write_text("This is not represented as an MIT-only product.\n")
        (self.root / "CONTRIBUTING.md").write_text("clone throttle-meter\nAll 21 tests should pass.\n")
        (self.root / "Sources").mkdir()
        (self.root / "Sources/App.swift").write_text("let value = 1\n")
        self.git("add", ".")
        self.git("commit", "-qm", "seed")

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.root, check=True, stdout=subprocess.PIPE)

    def policy(self, rules, review=None):
        path = self.root / "policy.json"
        path.write_text(json.dumps({
            "schema": inventory.POLICY_SCHEMA,
            "legalReview": review or {"status": "pending", "reviewer": None, "decisionRef": None},
            "rules": rules,
        }))
        return path

    @mock.patch.dict(os.environ, {"SOURCE_DATE_EPOCH": "0"})
    def test_unreviewed_inventory_is_factual_stable_and_incomplete(self):
        first = inventory.build_inventory(self.root)
        second = inventory.build_inventory(self.root)
        self.assertEqual(first, second)
        self.assertFalse(first["summary"]["complete"])
        self.assertEqual(first["summary"]["paths"], 4)
        source = next(item for item in first["files"] if item["path"] == "Sources/App.swift")
        self.assertTrue(source["tracked"])
        self.assertEqual(source["kind"], "source-or-script")
        self.assertEqual(len(source["sha256"]), 64)
        self.assertEqual(len(source["firstCommit"]), 40)
        self.assertEqual(first["inventoryDigest"], second["inventoryDigest"])
        self.assertEqual(
            {issue["id"] for issue in first["scopeIssues"]},
            {"root-license-scope-conflict", "stale-contributing-repository",
             "stale-contributing-test-count", "missing-security-policy"},
        )

    @mock.patch.dict(os.environ, {"SOURCE_DATE_EPOCH": "0"})
    def test_unstaged_tracked_deletion_is_reported_not_fatal(self):
        (self.root / "Sources/App.swift").unlink()
        document = inventory.build_inventory(self.root)
        self.assertEqual(document["summary"]["paths"], 3)
        self.assertNotIn("Sources/App.swift", {item["path"] for item in document["files"]})
        self.assertIn(
            {"id": "pending-tracked-deletion", "path": "Sources/App.swift", "status": "requires-owner-review"},
            document["scopeIssues"],
        )
        self.assertFalse(document["summary"]["complete"])

    def test_complete_requires_every_path_and_qualified_legal_review(self):
        review = {"status": "approved", "reviewer": "Counsel", "decisionRef": "legal-1"}
        path = self.policy([
            {"pattern": "LICENSE", "classification": "public", "rationale": "approved root licence"},
            {"pattern": "README.md", "classification": "public", "rationale": "public documentation"},
            {"pattern": "CONTRIBUTING.md", "classification": "public", "rationale": "public policy"},
            {"pattern": "Sources/**", "classification": "proprietary", "rationale": "reviewed application source"},
            {"pattern": "policy.json", "classification": "excluded", "rationale": "test input"},
        ], review)
        report = inventory.build_inventory(self.root, path)
        self.assertTrue(report["summary"]["complete"])
        self.assertEqual(report["summary"]["classifications"].get("unreviewed", 0), 0)

    def test_conflicting_rules_fail_closed(self):
        path = self.policy([
            {"pattern": "Sources/**", "classification": "public", "rationale": "one review"},
            {"pattern": "**/*.swift", "classification": "proprietary", "rationale": "another review"},
        ])
        report = inventory.build_inventory(self.root, path)
        source = next(item for item in report["files"] if item["path"] == "Sources/App.swift")
        self.assertEqual(source["classification"], "conflict")
        self.assertFalse(report["summary"]["complete"])

    def test_policy_rejects_parent_paths_duplicate_patterns_and_unreasoned_decisions(self):
        variants = [
            [{"pattern": "../secret", "classification": "public", "rationale": "no"}],
            [{"pattern": "A", "classification": "public", "rationale": "one"},
             {"pattern": "A", "classification": "public", "rationale": "two"}],
            [{"pattern": "A", "classification": "public", "rationale": ""}],
        ]
        for rules in variants:
            with self.subTest(rules=rules), self.assertRaises(inventory.InventoryError):
                inventory.load_policy(self.policy(rules))

    def test_symlink_hashes_the_link_target_without_following_it(self):
        outside = self.root.parent / (self.root.name + "-outside")
        outside.write_text("private")
        try:
            (self.root / "link").symlink_to(outside)
            report = inventory.build_inventory(self.root)
            link = next(item for item in report["files"] if item["path"] == "link")
            self.assertEqual(link["nodeType"], "symlink")
            self.assertEqual(link["sha256"], inventory.sha256(str(outside).encode()))
        finally:
            outside.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
