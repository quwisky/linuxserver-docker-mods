#!/usr/bin/env python3
"""Behavior tests for the VAAPI shipped-artifact fingerprint command."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


COMMAND = Path(__file__).resolve().parents[1] / "vaapi-fingerprint.py"


class VaapiFingerprintTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        library = self.root / "vaapi-amdgpu/lib"
        library.mkdir(parents=True)
        (library / "libva.so.2.0.0").write_bytes(b"libva-v1")
        (library / "libva.so.2").symlink_to("libva.so.2.0.0")
        database = self.root / "usr/share/libdrm/amdgpu.ids"
        database.parent.mkdir(parents=True)
        database.write_text("gpu-v1\n", encoding="utf-8")
        ignored = self.root / "etc/s6-overlay/service/run"
        ignored.parent.mkdir(parents=True)
        ignored.write_text("ignored\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def fingerprint(self) -> dict[str, object]:
        result = subprocess.run(
            ["python3", os.fspath(COMMAND), os.fspath(self.root)],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        )
        return json.loads(result.stdout)

    def test_fingerprint_contains_only_shipped_alpine_artifacts(self) -> None:
        result = self.fingerprint()

        self.assertEqual(
            [entry["path"] for entry in result["files"]],
            [
                "usr/share/libdrm/amdgpu.ids",
                "vaapi-amdgpu/lib/libva.so.2",
                "vaapi-amdgpu/lib/libva.so.2.0.0",
            ],
        )
        self.assertNotIn("etc/s6-overlay/service/run", json.dumps(result))
        link = result["files"][1]
        self.assertEqual(link["type"], "symlink")
        self.assertEqual(link["target"], "libva.so.2.0.0")

    def test_content_mode_and_symlink_changes_change_the_fingerprint(self) -> None:
        original = self.fingerprint()["fingerprint"]
        target = self.root / "vaapi-amdgpu/lib/libva.so.2.0.0"
        target.write_bytes(b"libva-v2")
        content = self.fingerprint()["fingerprint"]
        target.chmod(0o755)
        mode = self.fingerprint()["fingerprint"]
        (self.root / "vaapi-amdgpu/lib/libva.so.2").unlink()
        (self.root / "vaapi-amdgpu/lib/libva.so.2").symlink_to("other.so")
        link = self.fingerprint()["fingerprint"]

        self.assertEqual(len({original, content, mode, link}), 4)


if __name__ == "__main__":
    unittest.main()
