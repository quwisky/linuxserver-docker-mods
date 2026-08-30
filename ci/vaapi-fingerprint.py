#!/usr/bin/env python3
"""Fingerprint only Alpine-derived files shipped by the VAAPI mod."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
from typing import Any


def file_entry(root: Path, path: Path) -> dict[str, Any]:
    metadata = path.lstat()
    relative = path.relative_to(root).as_posix()
    entry: dict[str, Any] = {
        "path": relative,
        "mode": f"{stat.S_IMODE(metadata.st_mode):04o}",
    }
    if path.is_symlink():
        entry.update(type="symlink", target=os.readlink(path))
    elif path.is_file():
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        entry.update(type="file", sha256=digest.hexdigest())
    else:
        raise ValueError(f"unsupported shipped artifact type: {relative}")
    return entry


def fingerprint(root: Path) -> dict[str, Any]:
    root = root.resolve()
    library_root = root / "vaapi-amdgpu/lib"
    ids = root / "usr/share/libdrm/amdgpu.ids"
    if not library_root.is_dir():
        raise ValueError(f"{library_root} is missing")
    if not ids.is_file():
        raise ValueError(f"{ids} is missing")
    paths = [path for path in library_root.rglob("*") if path.is_file() or path.is_symlink()]
    paths.append(ids)
    files = [file_entry(root, path) for path in sorted(paths, key=lambda item: item.relative_to(root).as_posix())]
    canonical = json.dumps(files, sort_keys=True, separators=(",", ":")).encode()
    return {
        "schema": 1,
        "fingerprint": f"sha256:{hashlib.sha256(canonical).hexdigest()}",
        "files": files,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="exported final-image filesystem")
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    try:
        result = json.dumps(fingerprint(arguments.root), indent=2, sort_keys=True) + "\n"
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    if arguments.output:
        arguments.output.write_text(result, encoding="utf-8")
    else:
        print(result, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
