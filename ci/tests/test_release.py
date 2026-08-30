#!/usr/bin/env python3
"""Behavior tests for the repository release command."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


RELEASE = Path(__file__).resolve().parents[1] / "release.py"


class Repository:
    def __init__(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Release Tests")
        self.git("config", "user.email", "release-tests@example.invalid")

    def close(self) -> None:
        self._tmp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(
            ["git", *args],
            cwd=self.root,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        ).stdout.strip()

    def write(self, name: str, content: str = "") -> None:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def commit(self, message: str) -> str:
        self.git("add", ".")
        self.git("commit", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def release(self, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", os.fspath(RELEASE), "--repo", os.fspath(self.root), *args],
            cwd=self.root,
            check=check,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )


def add_mod(repo: Repository, app: str, mod: str, dockerfile: str = "FROM scratch\n") -> None:
    base = f"mods/{app}/{mod}"
    repo.write(f"{base}/Dockerfile", dockerfile)
    repo.write(f"{base}/README.md", f"# {app}-{mod}\n")
    repo.write(f"{base}/VERSION", "0.0.0\n")
    repo.write(f"{base}/CHANGELOG.md", "# Changelog\n")


class ReleaseCommandTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = Repository()

    def tearDown(self) -> None:
        self.repo.close()

    def test_packages_use_directory_identity_and_platform_override(self) -> None:
        add_mod(self.repo, "plex", "alpha")
        add_mod(self.repo, "plex", "vaapi", "FROM --platform=linux/amd64 alpine:edge\n")
        self.repo.write("mods/plex/vaapi/PLATFORMS", "linux/amd64\n")

        result = self.repo.release("packages")

        self.assertEqual(
            json.loads(result.stdout),
            [
                {
                    "app": "plex",
                    "dir": "mods/plex/alpha",
                    "id": "plex-alpha",
                    "mod": "alpha",
                    "platforms": "linux/amd64,linux/arm64",
                    "version": "0.0.0",
                },
                {
                    "app": "plex",
                    "dir": "mods/plex/vaapi",
                    "id": "plex-vaapi",
                    "mod": "vaapi",
                    "platforms": "linux/amd64",
                    "version": "0.0.0",
                },
            ],
        )

    def test_affected_expands_a_shared_input_to_every_consumer(self) -> None:
        shared = "shared/runtime"
        add_mod(self.repo, "plex", "alpha", f"FROM scratch\nCOPY {shared} /runtime\n")
        add_mod(self.repo, "qbittorrent", "beta", f"FROM scratch\nCOPY {shared} /runtime\n")
        self.repo.write(f"{shared}/helper.sh", "old\n")
        base = self.repo.commit("initial")
        self.repo.write(f"{shared}/helper.sh", "new\n")
        head = self.repo.commit("change shared runtime")

        result = self.repo.release("affected", "--base", base, "--head", head)

        affected = json.loads(result.stdout)
        self.assertEqual(
            [item["id"] for item in affected["include"]],
            ["plex-alpha", "qbittorrent-beta"],
        )

    def test_validate_requires_release_intent_for_runtime_changes(self) -> None:
        add_mod(self.repo, "plex", "alpha")
        self.repo.write("mods/plex/alpha/root/run", "old\n")
        base = self.repo.commit("initial")
        self.repo.write("mods/plex/alpha/root/run", "new\n")
        head = self.repo.commit("runtime change")

        result = self.repo.release(
            "validate", "--base", base, "--head", head, check=False
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("plex-alpha has runtime changes but no release intent", result.stderr)

    def test_validate_accepts_an_explicit_no_release_reason(self) -> None:
        add_mod(self.repo, "plex", "alpha")
        base = self.repo.commit("initial")
        self.repo.write("mods/plex/alpha/Dockerfile", "FROM scratch # metadata only\n")
        self.repo.write(
            ".changes/base-digest.json",
            json.dumps(
                {
                    "summary": "Refresh a pinned build input without changing shipped bytes.",
                    "packages": {"plex-alpha": "none"},
                }
            ),
        )
        head = self.repo.commit("pin digest")

        result = self.repo.release("validate", "--base", base, "--head", head)

        self.assertEqual(result.stdout.strip(), "release intent is valid")

    def test_plan_expands_shared_bumps_and_only_allows_stronger_overrides(self) -> None:
        shared = "shared/runtime"
        add_mod(self.repo, "plex", "alpha", f"FROM scratch\nCOPY {shared} /runtime\n")
        add_mod(self.repo, "qbittorrent", "beta", f"FROM scratch\nCOPY {shared} /runtime\n")
        self.repo.write(f"{shared}/helper.sh", "payload\n")
        self.repo.write(
            ".changes/shared.json",
            json.dumps(
                {
                    "summary": "Add the shared recovery behavior.",
                    "shared": {"runtime": "minor"},
                    "packages": {"plex-alpha": "major"},
                }
            ),
        )

        result = self.repo.release("plan")

        plan = json.loads(result.stdout)
        self.assertEqual(
            [(item["id"], item["previous_version"], item["version"]) for item in plan["packages"]],
            [
                ("plex-alpha", "0.0.0", "1.0.0"),
                ("qbittorrent-beta", "0.0.0", "0.1.0"),
            ],
        )
        self.assertEqual(plan["packages"][0]["notes"], ["Add the shared recovery behavior."])

    def test_prepare_updates_package_history_and_consumes_fragments(self) -> None:
        add_mod(self.repo, "plex", "alpha")
        self.repo.write(
            ".changes/fix.json",
            json.dumps(
                {
                    "summary": "Correct startup ordering.",
                    "packages": {"plex-alpha": "patch"},
                }
            ),
        )

        self.repo.release("prepare")

        self.assertEqual((self.repo.root / "mods/plex/alpha/VERSION").read_text(), "0.0.1\n")
        changelog = (self.repo.root / "mods/plex/alpha/CHANGELOG.md").read_text()
        self.assertIn("## 0.0.1", changelog)
        self.assertIn("- Correct startup ordering.", changelog)
        self.assertFalse((self.repo.root / ".changes/fix.json").exists())
        release_plan = json.loads((self.repo.root / ".release/plan.json").read_text())
        self.assertEqual(release_plan["packages"][0]["version"], "0.0.1")

    def test_plan_rejects_a_reviewed_candidate_mixed_with_another_change(self) -> None:
        add_mod(self.repo, "plex", "vaapi")
        candidate = {
            "ref": "ghcr.io/example/plex-vaapi:candidate-vaapi-deadbeef",
            "digest": f"sha256:{'a' * 64}",
        }
        self.repo.write(
            ".changes/vaapi.json",
            json.dumps(
                {
                    "summary": "Refresh the shipped VAAPI libraries.",
                    "packages": {"plex-vaapi": "patch"},
                    "candidates": {"plex-vaapi": candidate},
                }
            ),
        )
        self.repo.write(
            ".changes/follow-up.json",
            json.dumps(
                {
                    "summary": "Change another runtime input.",
                    "packages": {"plex-vaapi": "patch"},
                }
            ),
        )

        result = self.repo.release("plan", check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rebuild one candidate from the combined change", result.stderr)

    def test_verify_plan_matches_the_base_fragments_exactly(self) -> None:
        add_mod(self.repo, "plex", "alpha")
        self.repo.write(
            ".changes/fix.json",
            json.dumps(
                {
                    "summary": "Correct startup ordering.",
                    "packages": {"plex-alpha": "patch"},
                }
            ),
        )
        base = self.repo.commit("runtime change")
        self.repo.release("prepare")

        valid = self.repo.release("verify-plan", "--base", base)

        self.assertEqual(valid.stdout.strip(), "release plan is valid")
        plan_path = self.repo.root / ".release/plan.json"
        plan = json.loads(plan_path.read_text(encoding="utf-8"))
        plan["packages"][0]["notes"] = ["Unreviewed replacement note."]
        plan_path.write_text(json.dumps(plan), encoding="utf-8")
        invalid = self.repo.release("verify-plan", "--base", base, check=False)
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn("does not exactly match", invalid.stderr)

    def test_verify_plan_rejects_a_candidate_for_another_package(self) -> None:
        add_mod(self.repo, "plex", "alpha")
        self.repo.write(
            ".changes/fix.json",
            json.dumps(
                {
                    "summary": "Correct startup ordering.",
                    "packages": {"plex-alpha": "patch"},
                }
            ),
        )
        self.repo.commit("runtime change")
        self.repo.release("prepare")
        plan_path = self.repo.root / ".release/plan.json"
        plan = json.loads(plan_path.read_text(encoding="utf-8"))
        plan["packages"][0]["candidate_ref"] = "ghcr.io/example/plex-other:candidate-vaapi-bad"
        plan["packages"][0]["candidate_digest"] = f"sha256:{'a' * 64}"
        plan_path.write_text(json.dumps(plan), encoding="utf-8")

        result = self.repo.release("verify-plan", "--owner", "example", check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid candidate ref", result.stderr)


if __name__ == "__main__":
    unittest.main()
