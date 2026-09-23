#!/usr/bin/env python3
"""Build a factual, fail-closed IP inventory for the current Git worktree.

The inventory never infers that a path is public or proprietary. An optional
reviewed policy can classify exact glob patterns; everything else remains
``unreviewed`` and ``--require-complete`` fails. No network call is made.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import hashlib
import json
import os
import pathlib
import subprocess
import sys
from typing import Any


SCHEMA = "throttle-ip-inventory/v1"
POLICY_SCHEMA = "throttle-ip-policy/v1"
CLASSIFICATIONS = {"public", "proprietary", "third-party", "generated", "excluded"}


class InventoryError(ValueError):
    pass


def run_git(root: pathlib.Path, *args: str) -> bytes:
    process = subprocess.run(
        ["git", *args], cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False
    )
    if process.returncode:
        raise InventoryError(process.stderr.decode(errors="replace").strip() or "git command failed")
    return process.stdout


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def observed_at() -> str:
    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    instant = dt.datetime.fromtimestamp(int(epoch), tz=dt.timezone.utc) if epoch else dt.datetime.now(dt.timezone.utc)
    return instant.isoformat().replace("+00:00", "Z")


def listed_paths(root: pathlib.Path) -> tuple[list[str], set[str]]:
    tracked = {
        item.decode("utf-8", errors="surrogateescape")
        for item in run_git(root, "ls-files", "-z").split(b"\0") if item
    }
    visible = {
        item.decode("utf-8", errors="surrogateescape")
        for item in run_git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard").split(b"\0")
        if item
    }
    return sorted(visible), tracked


def pending_deletions(root: pathlib.Path) -> list[str]:
    """Tracked paths removed from the worktree without a staged deletion.

    They have no working file to hash, so they are reported as review issues
    instead of aborting the whole inventory or silently vanishing from it.
    """
    return sorted(
        item.decode("utf-8", errors="surrogateescape")
        for item in run_git(root, "ls-files", "-z", "--deleted").split(b"\0") if item
    )


def commit_provenance(root: pathlib.Path) -> tuple[dict[str, str], dict[str, str]]:
    output = run_git(root, "log", "--all", "--reverse", "--format=%x1e%H%x00", "--name-only", "-z")
    first: dict[str, str] = {}
    latest: dict[str, str] = {}
    for record in output.split(b"\x1e")[1:]:
        fields = record.split(b"\0")
        commit = fields[0].decode("ascii", errors="ignore")
        if len(commit) != 40:
            continue
        for raw in fields[1:]:
            path = raw.lstrip(b"\n").decode("utf-8", errors="surrogateescape")
            if not path:
                continue
            first.setdefault(path, commit)
            latest[path] = commit
    return first, latest


def load_policy(path: pathlib.Path | None) -> tuple[dict[str, Any], str | None]:
    if path is None:
        return {
            "schema": POLICY_SCHEMA,
            "legalReview": {"status": "pending", "reviewer": None, "decisionRef": None},
            "rules": [],
        }, None
    try:
        raw = path.read_bytes()
        policy = json.loads(raw)
    except (OSError, json.JSONDecodeError) as error:
        raise InventoryError(f"invalid policy: {error}") from error
    if not isinstance(policy, dict) or policy.get("schema") != POLICY_SCHEMA:
        raise InventoryError("unsupported policy schema")
    review = policy.get("legalReview")
    if not isinstance(review, dict) or review.get("status") not in {"pending", "approved", "rejected"}:
        raise InventoryError("invalid legalReview")
    rules = policy.get("rules")
    if not isinstance(rules, list):
        raise InventoryError("rules must be a list")
    seen = set()
    for rule in rules:
        if not isinstance(rule, dict) or set(rule) - {"pattern", "classification", "rationale", "decisionRef"}:
            raise InventoryError("invalid policy rule shape")
        pattern, classification = rule.get("pattern"), rule.get("classification")
        if not isinstance(pattern, str) or not pattern or pattern.startswith("/") or ".." in pathlib.PurePosixPath(pattern).parts:
            raise InventoryError("policy patterns must be non-empty repository-relative globs")
        if pattern in seen:
            raise InventoryError("duplicate policy pattern: " + pattern)
        if classification not in CLASSIFICATIONS:
            raise InventoryError("invalid classification: " + str(classification))
        if not isinstance(rule.get("rationale"), str) or not rule["rationale"].strip():
            raise InventoryError("every classification needs a rationale")
        seen.add(pattern)
    return policy, sha256(raw)


def classification(path: str, policy: dict[str, Any]) -> tuple[str, list[str], list[str]]:
    matches = [rule for rule in policy["rules"] if fnmatch.fnmatchcase(path, rule["pattern"])]
    values = sorted({rule["classification"] for rule in matches})
    if len(values) > 1:
        return "conflict", [rule["pattern"] for rule in matches], values
    return (values[0] if values else "unreviewed"), [rule["pattern"] for rule in matches], values


def file_kind(path: str) -> str:
    name = pathlib.PurePosixPath(path).name.lower()
    suffix = pathlib.PurePosixPath(path).suffix.lower()
    if name in {"license", "license.md", "copying", "notice", "third_party_notices.md"}:
        return "license-or-notice"
    if name in {"package.resolved", "package-lock.json", "podfile.lock", "cartfile.resolved"}:
        return "dependency-lock"
    if "/tests/" in "/" + path.lower() or name.startswith("test_") or name.endswith("tests.swift"):
        return "test"
    if suffix in {".swift", ".m", ".mm", ".h", ".c", ".cc", ".cpp", ".js", ".mjs", ".ts", ".py", ".rb", ".sh"}:
        return "source-or-script"
    if suffix in {".md", ".txt", ".html"}:
        return "documentation"
    if suffix in {".png", ".jpg", ".jpeg", ".gif", ".pdf", ".icns", ".svg", ".xcassets"} or ".xcassets/" in path:
        return "asset"
    if suffix in {".json", ".yml", ".yaml", ".plist", ".entitlements", ".xcprivacy", ".toml"}:
        return "configuration-or-data"
    return "other"


def file_record(
    root: pathlib.Path, relative: str, tracked: set[str], first: dict[str, str], latest: dict[str, str], policy: dict[str, Any]
) -> dict[str, Any]:
    path = root / pathlib.PurePosixPath(relative)
    if path.is_symlink():
        payload = os.readlink(path).encode("utf-8", errors="surrogateescape")
        node_type = "symlink"
    elif path.is_file():
        payload = path.read_bytes()
        node_type = "file"
    else:
        raise InventoryError("listed path is not a regular file or symlink: " + relative)
    selected, patterns, conflicts = classification(relative, policy)
    return {
        "path": relative,
        "tracked": relative in tracked,
        "nodeType": node_type,
        "kind": file_kind(relative),
        "bytes": len(payload),
        "sha256": sha256(payload),
        "firstCommit": first.get(relative),
        "latestCommit": latest.get(relative),
        "classification": selected,
        "policyPatterns": patterns,
        "classificationConflicts": conflicts if selected == "conflict" else [],
    }


def dependency_records(root: pathlib.Path, paths: list[str]) -> list[dict[str, Any]]:
    result = []
    for relative in paths:
        name = pathlib.PurePosixPath(relative).name
        if name == "Package.resolved":
            try:
                pins = json.loads((root / relative).read_text()).get("pins", [])
            except (OSError, json.JSONDecodeError, AttributeError):
                result.append({"manifest": relative, "error": "invalid Package.resolved"})
                continue
            for pin in pins if isinstance(pins, list) else []:
                state = pin.get("state", {}) if isinstance(pin, dict) else {}
                result.append({
                    "manifest": relative,
                    "identity": pin.get("identity"),
                    "location": pin.get("location"),
                    "version": state.get("version"),
                    "revision": state.get("revision"),
                })
        elif name == "package-lock.json":
            try:
                document = json.loads((root / relative).read_text())
            except (OSError, json.JSONDecodeError):
                result.append({"manifest": relative, "error": "invalid package-lock.json"})
                continue
            for package_path, package in sorted(document.get("packages", {}).items()):
                if package_path and isinstance(package, dict):
                    result.append({
                        "manifest": relative,
                        "identity": package_path.removeprefix("node_modules/"),
                        "version": package.get("version"),
                        "resolved": package.get("resolved"),
                        "integrity": package.get("integrity"),
                    })
    return sorted(result, key=lambda value: (str(value.get("manifest")), str(value.get("identity"))))


def scope_issues(root: pathlib.Path) -> list[dict[str, str]]:
    issues = []
    license_text = (root / "LICENSE").read_text(errors="replace") if (root / "LICENSE").is_file() else ""
    readme = (root / "README.md").read_text(errors="replace") if (root / "README.md").is_file() else ""
    contributing = (root / "CONTRIBUTING.md").read_text(errors="replace") if (root / "CONTRIBUTING.md").is_file() else ""
    if "MIT License" in license_text and "not represented as an MIT-only" in readme:
        issues.append({"id": "root-license-scope-conflict", "status": "requires-legal-review"})
    if "throttle-meter" in contributing:
        issues.append({"id": "stale-contributing-repository", "status": "requires-owner-review"})
    if "All 21 tests" in contributing:
        issues.append({"id": "stale-contributing-test-count", "status": "requires-owner-review"})
    if not (root / "SECURITY.md").is_file():
        issues.append({"id": "missing-security-policy", "status": "requires-owner-review"})
    return issues


def build_inventory(root: pathlib.Path, policy_path: pathlib.Path | None = None) -> dict[str, Any]:
    canonical = pathlib.Path(run_git(root, "rev-parse", "--show-toplevel").decode().strip()).resolve()
    if canonical != root.resolve():
        raise InventoryError("root must be the Git toplevel")
    paths, tracked = listed_paths(canonical)
    deleted = pending_deletions(canonical)
    paths = [path for path in paths if path not in set(deleted)]
    first, latest = commit_provenance(canonical)
    policy, policy_digest = load_policy(policy_path)
    files = [file_record(canonical, path, tracked, first, latest, policy) for path in paths]
    counts: dict[str, int] = {}
    for record in files:
        counts[record["classification"]] = counts.get(record["classification"], 0) + 1
    review = policy["legalReview"]
    complete = bool(files) and counts.get("unreviewed", 0) == 0 and counts.get("conflict", 0) == 0 \
        and review.get("status") == "approved" and bool(review.get("reviewer")) and bool(review.get("decisionRef"))
    document: dict[str, Any] = {
        "schema": SCHEMA,
        "observedAt": observed_at(),
        "repository": {
            "head": run_git(canonical, "rev-parse", "HEAD").decode().strip(),
            "branch": run_git(canonical, "branch", "--show-current").decode().strip(),
            "statusPorcelainV2SHA256": sha256(run_git(canonical, "status", "--porcelain=v2", "-z")),
        },
        "policy": {"sha256": policy_digest, "legalReview": review},
        "summary": {"paths": len(files), "classifications": counts, "complete": complete},
        "scopeIssues": scope_issues(canonical) + [
            {"id": "pending-tracked-deletion", "path": path, "status": "requires-owner-review"}
            for path in deleted
        ],
        "files": files,
        "dependencies": dependency_records(canonical, paths),
    }
    digest_material = dict(document)
    digest_material.pop("observedAt")
    document["inventoryDigest"] = sha256(canonical_json(digest_material))
    return document


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument("--policy", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--require-complete", action="store_true")
    args = parser.parse_args()
    try:
        inventory = build_inventory(args.root, args.policy)
    except InventoryError as error:
        print(f"ip-inventory: {error}", file=sys.stderr)
        return 2
    payload = json.dumps(inventory, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload)
    else:
        sys.stdout.write(payload)
    if args.require_complete and not inventory["summary"]["complete"]:
        print("ip-inventory: classification or legal review is incomplete", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
