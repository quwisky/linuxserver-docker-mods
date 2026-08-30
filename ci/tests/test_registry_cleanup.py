#!/usr/bin/env python3
"""Behavior tests for registry retention safety."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


CLEANUP = Path(__file__).resolve().parents[1] / "cleanup-package-tags.sh"


class RegistryCleanupTests(unittest.TestCase):
    def test_candidate_cleanup_deletes_only_old_candidate_only_versions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            mock_bin = root / "bin"
            mock_bin.mkdir()
            log = root / "deletes.log"
            versions = [
                version(1, "2026-01-05", [f"sha-{'a' * 40}"]),
                version(2, "2026-01-04", ["candidate-vaapi-bbbbbbbbbbbb-42"]),
                version(3, "2026-01-03", [f"sha-{'c' * 40}", "1.0.0"]),
                version(4, "2026-01-02", [f"sha-{'d' * 40}"]),
            ]
            gh = mock_bin / "gh"
            gh.write_text(
                """#!/usr/bin/env bash
set -euo pipefail
if [[ $* == 'api users/example --jq .type' ]]; then
    printf 'User\\n'
elif [[ $* == *'--paginate --slurp'* ]]; then
    printf '%s\\n' "${MOCK_VERSIONS}"
elif [[ $* == api\\ --method\\ DELETE* ]]; then
    printf '%s\\n' "$*" >>"${MOCK_DELETE_LOG}"
else
    printf 'unexpected gh call: %s\\n' "$*" >&2
    exit 1
fi
""",
                encoding="utf-8",
            )
            gh.chmod(0o755)
            environment = {
                **os.environ,
                "PATH": f"{mock_bin}:{os.environ['PATH']}",
                "GH_TOKEN": "test-token",
                "GITHUB_REPOSITORY_OWNER": "example",
                "MOCK_VERSIONS": json.dumps([versions]),
                "MOCK_DELETE_LOG": os.fspath(log),
            }

            subprocess.run(
                [os.fspath(CLEANUP), "plex-vaapi-amdgpu-mod", "candidates", "2"],
                check=True,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            deleted = log.read_text(encoding="utf-8")
            self.assertEqual(deleted.count("versions/4"), 1)
            self.assertNotIn("versions/3", deleted)


def version(identifier: int, updated: str, tags: list[str]) -> dict[str, object]:
    return {
        "id": identifier,
        "updated_at": f"{updated}T00:00:00Z",
        "metadata": {"container": {"tags": tags}},
    }


if __name__ == "__main__":
    unittest.main()
