#!/usr/bin/env python3
"""Behavior tests for keeping the Release Please pull request current."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SYNC = Path(__file__).resolve().parents[1] / "sync-release-pr.sh"


class ReleasePullRequestSyncTests(unittest.TestCase):
    def run_sync(
        self, gh_behavior: str
    ) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            mock_bin = root / "bin"
            mock_bin.mkdir()
            log = root / "gh.log"
            gh = mock_bin / "gh"
            gh.write_text(
                """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >>"${MOCK_GH_LOG}"
"""
                + gh_behavior,
                encoding="utf-8",
            )
            gh.chmod(0o755)
            environment = {
                **os.environ,
                "PATH": f"{mock_bin}:{os.environ['PATH']}",
                "GH_TOKEN": "test-token",
                "GITHUB_REPOSITORY": "example/repo",
                "MOCK_GH_LOG": os.fspath(log),
            }
            completed = subprocess.run(
                [os.fspath(SYNC)],
                check=True,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            return completed, log.read_text(encoding="utf-8").splitlines()

    def test_behind_release_pull_request_is_updated_with_expected_head(self) -> None:
        completed, calls = self.run_sync(
            """
case "$*" in
    'api --method GET repos/example/repo/pulls -f state=open -f base=master -f head=example:release-please--branches--master')
        printf '%s\\n' '[{"number":11,"head":{"sha":"release-sha"},"base":{"sha":"stale-base-sha"}}]'
        ;;
    'api repos/example/repo/commits/master')
        printf '%s\\n' '{"sha":"current-master-sha"}'
        ;;
    'api repos/example/repo/compare/current-master-sha...release-sha')
        printf '%s\\n' '{"behind_by":2}'
        ;;
    'api --method PUT repos/example/repo/pulls/11/update-branch -f expected_head_sha=release-sha')
        printf '%s\\n' '{"message":"Updating pull request branch."}'
        ;;
    *)
        printf 'unexpected gh call: %s\\n' "$*" >&2
        exit 1
        ;;
esac
"""
        )

        self.assertIn("updating release pull request #11", completed.stdout)
        self.assertTrue(
            any(
                "pulls/11/update-branch -f expected_head_sha=release-sha" in call
                for call in calls
            )
        )

    def test_no_open_release_pull_request_is_a_no_op(self) -> None:
        completed, calls = self.run_sync(
            """
if [[ $* == 'api --method GET repos/example/repo/pulls -f state=open -f base=master -f head=example:release-please--branches--master' ]]; then
    printf '%s\\n' '[]'
else
    printf 'unexpected gh call: %s\\n' "$*" >&2
    exit 1
fi
"""
        )

        self.assertEqual(completed.stdout, "no open release pull request\n")
        self.assertEqual(len(calls), 1)

    def test_current_release_pull_request_is_not_updated(self) -> None:
        completed, calls = self.run_sync(
            """
case "$*" in
    'api --method GET repos/example/repo/pulls -f state=open -f base=master -f head=example:release-please--branches--master')
        printf '%s\\n' '[{"number":11,"head":{"sha":"release-sha"},"base":{"sha":"stale-base-sha"}}]'
        ;;
    'api repos/example/repo/commits/master')
        printf '%s\\n' '{"sha":"current-master-sha"}'
        ;;
    'api repos/example/repo/compare/current-master-sha...release-sha')
        printf '%s\\n' '{"behind_by":0}'
        ;;
    *)
        printf 'unexpected gh call: %s\\n' "$*" >&2
        exit 1
        ;;
esac
"""
        )

        self.assertEqual(completed.stdout, "release pull request #11 is current\n")
        self.assertEqual(len(calls), 3)
        self.assertNotIn("update-branch", "\n".join(calls))


if __name__ == "__main__":
    unittest.main()
