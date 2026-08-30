#!/usr/bin/env python3
"""Behavior tests for published-manifest verification."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


VERIFY = Path(__file__).resolve().parents[1] / "verify-published-mod.sh"


class RegistryVerificationTests(unittest.TestCase):
    def test_digest_qualified_tag_uses_the_repository_without_its_tag(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            mock_bin = root / "bin"
            mock_bin.mkdir()
            log = root / "curl.log"
            curl = mock_bin / "curl"
            curl.write_text(
                """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >>"${MOCK_CURL_LOG}"
url="${!#}"
if [[ ${url} == https://ghcr.io/token* ]]; then
    printf '{"token":"test-token"}\\n'
elif [[ ${url} == */manifests/sha256:* ]]; then
    printf '{"layers":[{"digest":"sha256:layer"}]}\\n200'
else
    printf 'unexpected URL: %s\\n' "${url}" >&2
    exit 1
fi
""",
                encoding="utf-8",
            )
            curl.chmod(0o755)
            digest = f"sha256:{'a' * 64}"
            environment = {
                **os.environ,
                "PATH": f"{mock_bin}:{os.environ['PATH']}",
                "GH_USER": "test-user",
                "GH_PASS": "test-token",
                "MOCK_CURL_LOG": os.fspath(log),
            }

            subprocess.run(
                [os.fspath(VERIFY), f"ghcr.io/example/plex-alpha:sha-deadbeef@{digest}"],
                check=True,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            calls = log.read_text(encoding="utf-8")
            self.assertIn("scope=repository:example/plex-alpha:pull", calls)
            self.assertIn(f"/v2/example/plex-alpha/manifests/{digest}", calls)
            self.assertNotIn("repository:example/plex-alpha:sha-deadbeef:pull", calls)


if __name__ == "__main__":
    unittest.main()
