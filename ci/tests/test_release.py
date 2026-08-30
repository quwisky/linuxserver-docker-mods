#!/usr/bin/env python3
"""Behavior tests for the Release Please repository adapter."""

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
            ["git", *args], cwd=self.root, check=True, text=True, stdout=subprocess.PIPE
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

    def validate(self, base: str, head: str, title: str, **overrides: str) -> subprocess.CompletedProcess[str]:
        values = {
            "body": "",
            "head_ref": "feature",
            "head_repo": "example/repo",
            "repository": "example/repo",
            "author": "maintainer",
            "expected_release_author": "release-app[bot]",
        }
        values.update(overrides)
        return self.repo.release(
            "validate-pr",
            "--base", base,
            "--head", head,
            "--title", values.get("title", title),
            "--body", values["body"],
            "--head-ref", values["head_ref"],
            "--head-repo", values["head_repo"],
            "--repository", values["repository"],
            "--author", values["author"],
            "--expected-release-author", values["expected_release_author"],
            check=False,
        )

    def test_packages_use_directory_identity_and_platform_override(self) -> None:
        add_mod(self.repo, "plex", "alpha")
        add_mod(self.repo, "plex", "vaapi")
        self.repo.write("mods/plex/vaapi/PLATFORMS", "linux/amd64\n")
        packages = json.loads(self.repo.release("packages").stdout)
        self.assertEqual([item["id"] for item in packages], ["plex-alpha", "plex-vaapi"])
        self.assertEqual(packages[1]["platforms"], "linux/amd64")

    def test_affected_expands_shared_input_to_every_consumer(self) -> None:
        shared = "shared/runtime"
        add_mod(self.repo, "plex", "alpha", f"FROM scratch\nCOPY {shared}/ /runtime/\n")
        add_mod(self.repo, "qbittorrent", "beta", f"FROM scratch\nCOPY {shared}/ /runtime/\n")
        self.repo.write(f"{shared}/helper.sh", "old\n")
        self.repo.release("shared-markers", "--write")
        base = self.repo.commit("initial")
        self.repo.write(f"{shared}/helper.sh", "new\n")
        head = self.repo.commit("change shared runtime")
        affected = json.loads(
            self.repo.release("affected", "--base", base, "--head", head).stdout
        )
        self.assertEqual(
            [item["id"] for item in affected["include"]],
            ["plex-alpha", "qbittorrent-beta"],
        )

    def test_shared_marker_check_rejects_stale_consumers(self) -> None:
        add_mod(self.repo, "plex", "alpha", "FROM scratch\nCOPY shared/runtime/ /runtime/\n")
        self.repo.write("shared/runtime/helper.sh", "old\n")
        self.repo.release("shared-markers", "--write")
        self.repo.write("shared/runtime/helper.sh", "new\n")
        result = self.repo.release("shared-markers", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is stale", result.stderr)

    def test_runtime_change_requires_releasable_title(self) -> None:
        add_mod(self.repo, "plex", "alpha")
        self.repo.write("mods/plex/alpha/root/run", "old\n")
        base = self.repo.commit("initial")
        self.repo.write("mods/plex/alpha/root/run", "new\n")
        head = self.repo.commit("change")
        invalid = self.validate(base, head, "chore(plex-alpha): adjust runtime")
        valid = self.validate(base, head, "fix(plex-alpha): adjust runtime")
        self.assertNotEqual(invalid.returncode, 0)
        self.assertEqual(valid.returncode, 0, valid.stderr)

    def test_releasable_title_rejects_metadata_only_package(self) -> None:
        add_mod(self.repo, "plex", "alpha")
        base = self.repo.commit("initial")
        self.repo.write("mods/plex/alpha/README.md", "docs only\n")
        head = self.repo.commit("docs")
        result = self.validate(base, head, "fix(plex-alpha): clarify setup")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no runtime or audited artifact", result.stderr)

    def test_initial_release_metadata_is_a_one_time_release_signal(self) -> None:
        add_mod(self.repo, "plex", "alpha")
        (self.repo.root / "mods/plex/alpha/VERSION").unlink()
        (self.repo.root / "mods/plex/alpha/CHANGELOG.md").unlink()
        base = self.repo.commit("pre-release repository")
        self.repo.write("mods/plex/alpha/VERSION", "0.0.0\n")
        self.repo.write("mods/plex/alpha/CHANGELOG.md", "# Changelog\n")
        head = self.repo.commit("bootstrap release metadata")

        result = self.validate(base, head, "feat(ci): bootstrap package releases")

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_renovate_alpine_digest_is_the_only_nonrelease_runtime_exception(self) -> None:
        add_mod(self.repo, "plex", "vaapi-amdgpu-mod", "FROM alpine:edge\n")
        base = self.repo.commit("initial")
        self.repo.write(
            "mods/plex/vaapi-amdgpu-mod/Dockerfile",
            f"FROM alpine:edge@sha256:{'a' * 64}\n",
        )
        head = self.repo.commit("pin")
        result = self.validate(base, head, "chore(deps): pin alpine digest")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_release_as_footer_is_forbidden(self) -> None:
        add_mod(self.repo, "plex", "alpha")
        base = self.repo.commit("initial")
        self.repo.write("mods/plex/alpha/root/run", "new\n")
        head = self.repo.commit("change")
        result = self.validate(
            base, head, "fix(plex-alpha): adjust runtime", body="Release-As: 9.9.9"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Release-As overrides are forbidden", result.stderr)

    def test_release_please_pr_requires_app_identity_and_generated_files(self) -> None:
        add_mod(self.repo, "plex", "alpha")
        self.repo.write(".release-please-manifest.json", "{}\n")
        base = self.repo.commit("initial")
        self.repo.write("mods/plex/alpha/VERSION", "1.0.0\n")
        self.repo.write("mods/plex/alpha/CHANGELOG.md", "# Changelog\n\n## 1.0.0\n")
        self.repo.write(".release-please-manifest.json", '{"mods/plex/alpha":"1.0.0"}\n')
        head = self.repo.commit("release")
        valid = self.validate(
            base,
            head,
            "chore(master): release plex-alpha 1.0.0",
            head_ref="release-please--branches--master",
            author="release-app[bot]",
        )
        invalid = self.validate(
            base,
            head,
            "chore(master): release plex-alpha 1.0.0",
            head_ref="release-please--branches--master",
            author="maintainer",
        )
        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertNotEqual(invalid.returncode, 0)

    def test_release_matrix_discovers_draft_and_reuses_new_vaapi_candidate(self) -> None:
        add_mod(self.repo, "plex", "vaapi-amdgpu-mod")
        source = self.repo.commit("runtime source")
        fingerprint = f"sha256:{'b' * 64}"
        candidate_digest = f"sha256:{'c' * 64}"
        directory = "mods/plex/vaapi-amdgpu-mod"
        self.repo.write(
            f"{directory}/VAAPI-FINGERPRINT.json",
            json.dumps({"fingerprint": fingerprint}) + "\n",
        )
        self.repo.write(
            f"{directory}/VAAPI-CANDIDATE.json",
            json.dumps(
                {
                    "fingerprint": fingerprint,
                    "ref": "ghcr.io/example/plex-vaapi-amdgpu-mod:candidate-vaapi-test",
                    "digest": candidate_digest,
                    "source_sha": source,
                }
            )
            + "\n",
        )
        self.repo.write(f"{directory}/VERSION", "1.0.0\n")
        self.repo.commit("release metadata")
        self.repo.git("tag", "plex-vaapi-amdgpu-mod/v1.0.0")
        releases = self.repo.root / "releases.json"
        releases.write_text(
            json.dumps([[{"draft": True, "tag_name": "plex-vaapi-amdgpu-mod/v1.0.0"}]]),
            encoding="utf-8",
        )

        result = self.repo.release(
            "release-matrix", "--releases", os.fspath(releases), "--owner", "example"
        )

        item = json.loads(result.stdout)["include"][0]
        self.assertEqual(item["version"], "1.0.0")
        self.assertEqual(item["candidate_digest"], candidate_digest)
        self.assertEqual(item["source_sha"], self.repo.git("rev-parse", "HEAD"))


if __name__ == "__main__":
    unittest.main()
