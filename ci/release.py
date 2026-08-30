#!/usr/bin/env python3
"""Release Please integration and package discovery for Docker Mods.

Release Please owns versions, changelogs, tags, and draft GitHub Releases.
This command keeps only repository-specific policy: affected-package routing,
shared-input markers, Conventional PR validation, and trusted draft discovery.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
from typing import Any, Iterable


DEFAULT_PLATFORMS = "linux/amd64,linux/arm64"
PLATFORMS = re.compile(r"^linux/(?:amd64|arm64)(?:,linux/(?:amd64|arm64))*$")
SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
CONVENTIONAL = re.compile(
    r"^(?P<type>feat|fix|chore|build|docs|test|ci|refactor|style|revert)"
    r"(?:\([a-z0-9][a-z0-9._/-]*\))?(?P<breaking>!)?: [^\s].+$"
)
SHARED_COPY = re.compile(r"(?:^|\s)(shared/[A-Za-z0-9._/-]+)")
RUNTIME_NAMES = {"Dockerfile", "PLATFORMS"}
RELEASE_BRANCH = "release-please--branches--master"
SHARED_MARKER = ".release-please-shared.json"
VAAPI_CANDIDATE = "VAAPI-CANDIDATE.json"
VAAPI_FINGERPRINT = "VAAPI-FINGERPRINT.json"
RELEASE_PR_FILES = re.compile(
    r"^(?:\.release-please-manifest\.json|mods/[^/]+/[^/]+/(?:VERSION|CHANGELOG\.md))$"
)


class ReleaseError(RuntimeError):
    """A user-facing release contract failure."""


@dataclass(frozen=True)
class Package:
    app: str
    mod: str
    id: str
    dir: str
    platforms: str
    version: str


def run_git(repo: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode:
        raise ReleaseError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout.strip()


def read_one_line(path: Path, default: str | None = None) -> str:
    if not path.is_file():
        if default is not None:
            return default
        raise ReleaseError(f"{path} is missing")
    lines = path.read_text(encoding="utf-8").splitlines()
    if len(lines) != 1 or not lines[0].strip():
        raise ReleaseError(f"{path} must contain exactly one non-empty line")
    return lines[0].strip()


def discover_packages(repo: Path) -> list[Package]:
    packages: list[Package] = []
    seen: dict[str, str] = {}
    mods = repo / "mods"
    if not mods.is_dir():
        return packages
    for dockerfile in sorted(mods.glob("*/*/Dockerfile")):
        directory = dockerfile.parent
        app = directory.parent.name
        mod = directory.name
        package_id = f"{app}-{mod}"
        relative = directory.relative_to(repo).as_posix()
        if package_id in seen:
            raise ReleaseError(
                f"{relative} and {seen[package_id]} both compose to package id {package_id}"
            )
        seen[package_id] = relative
        version = read_one_line(directory / "VERSION", "0.0.0")
        if not SEMVER.fullmatch(version):
            raise ReleaseError(f"{relative}/VERSION is not a plain SemVer version: {version}")
        platforms = read_one_line(directory / "PLATFORMS", DEFAULT_PLATFORMS)
        if not PLATFORMS.fullmatch(platforms):
            raise ReleaseError(f"{relative}/PLATFORMS is unsupported: {platforms}")
        packages.append(Package(app, mod, package_id, relative, platforms, version))
    return packages


def shared_inputs(repo: Path, package: Package) -> set[str]:
    result: set[str] = set()
    dockerfile = repo / package.dir / "Dockerfile"
    for line in dockerfile.read_text(encoding="utf-8").splitlines():
        if not line.lstrip().startswith("COPY"):
            continue
        for match in SHARED_COPY.finditer(line):
            parts = match.group(1).split("/")
            if len(parts) >= 2:
                result.add(parts[1])
    return result


def consumers(repo: Path, packages: Iterable[Package]) -> dict[str, set[str]]:
    result: dict[str, set[str]] = {}
    for package in packages:
        for component in shared_inputs(repo, package):
            result.setdefault(component, set()).add(package.id)
    return result


def changed_files(repo: Path, base: str, head: str) -> list[str]:
    output = run_git(repo, "diff", "--name-only", "--diff-filter=ACDMRTUXB", base, head)
    return [line for line in output.splitlines() if line]


def shared_digest(directory: Path) -> str:
    if not directory.is_dir():
        raise ReleaseError(f"shared component is missing: {directory}")
    digest = hashlib.sha256()
    for path in sorted(directory.rglob("*"), key=lambda item: item.relative_to(directory).as_posix()):
        # Git does not store directory modes (or empty directories), so hashing
        # them would make the marker depend on the checkout's umask.
        if path.is_dir() and not path.is_symlink():
            continue
        relative = path.relative_to(directory).as_posix()
        metadata = path.lstat()
        mode = stat.S_IMODE(metadata.st_mode)
        if path.is_symlink():
            kind = "symlink"
            mode = 0
            payload = os.readlink(path).encode()
        elif path.is_file():
            kind = "file"
            # Git preserves only the executable bit, not group/other write
            # permissions inherited from a checkout's umask.
            mode = 0o755 if mode & 0o111 else 0o644
            payload = path.read_bytes()
        else:
            raise ReleaseError(f"unsupported shared input: {path}")
        digest.update(f"{relative}\0{kind}\0{mode:o}\0".encode())
        digest.update(payload)
        digest.update(b"\0")
    return f"sha256:{digest.hexdigest()}"


def expected_shared_marker(repo: Path, package: Package) -> dict[str, str]:
    return {
        component: shared_digest(repo / "shared" / component)
        for component in sorted(shared_inputs(repo, package))
    }


def shared_markers(repo: Path, write: bool) -> list[str]:
    changed: list[str] = []
    for package in discover_packages(repo):
        marker = repo / package.dir / SHARED_MARKER
        expected = expected_shared_marker(repo, package)
        rendered = json.dumps(expected, indent=2, sort_keys=True) + "\n"
        current = marker.read_text(encoding="utf-8") if marker.is_file() else ""
        if expected:
            if current != rendered:
                if not write:
                    raise ReleaseError(
                        f"{marker.relative_to(repo)} is stale; run "
                        "python3 ci/release.py shared-markers --write"
                    )
                marker.write_text(rendered, encoding="utf-8")
                changed.append(marker.relative_to(repo).as_posix())
        elif marker.exists():
            if not write:
                raise ReleaseError(f"{marker.relative_to(repo)} is obsolete")
            marker.unlink()
            changed.append(marker.relative_to(repo).as_posix())
    return changed


def runtime_packages(repo: Path, packages: list[Package], paths: Iterable[str]) -> set[str]:
    by_shared = consumers(repo, packages)
    result: set[str] = set()
    for path in paths:
        if path.startswith("shared/"):
            parts = path.split("/")
            if len(parts) >= 2:
                result.update(by_shared.get(parts[1], set()))
            continue
        for package in packages:
            prefix = f"{package.dir}/"
            if not path.startswith(prefix):
                continue
            relative = path[len(prefix) :]
            if relative.startswith("root/") or relative in RUNTIME_NAMES:
                result.add(package.id)
    return result


def routed_packages(packages: list[Package], paths: Iterable[str]) -> set[str]:
    return {
        package.id
        for package in packages
        for path in paths
        if path.startswith(f"{package.dir}/")
    }


def signal_packages(packages: list[Package], paths: Iterable[str]) -> set[str]:
    path_set = set(paths)
    return {
        package.id
        for package in packages
        if f"{package.dir}/{VAAPI_CANDIDATE}" in path_set
    }


def bootstrap_packages(repo: Path, packages: list[Package], base: str, head: str) -> set[str]:
    """Return packages receiving their one-time release metadata bootstrap."""
    result: set[str] = set()
    for package in packages:
        metadata = [f"{package.dir}/VERSION", f"{package.dir}/CHANGELOG.md"]
        absent_at_base = all(
            subprocess.run(
                ["git", "cat-file", "-e", f"{base}:{path}"],
                cwd=repo,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ).returncode
            for path in metadata
        )
        present_at_head = all(
            subprocess.run(
                ["git", "cat-file", "-e", f"{head}:{path}"],
                cwd=repo,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ).returncode
            == 0
            for path in metadata
        )
        if absent_at_base and present_at_head:
            result.add(package.id)
    return result


def affected_packages(repo: Path, base: str, head: str, runtime_only: bool) -> dict[str, Any]:
    packages = discover_packages(repo)
    by_shared = consumers(repo, packages)
    paths = changed_files(repo, base, head)
    affected: set[str] = set()
    global_ci = {
        ".dockerignore",
        ".github/workflows/_mod-ci.yml",
        ".github/workflows/_mod-publish.yml",
        ".github/workflows/ci.yml",
        "ci/release.py",
        "ci/mod-inputs.sh",
        "ci/verify-published-mod.sh",
    }
    if not runtime_only and any(path in global_ci or path.startswith("template/") for path in paths):
        affected = {package.id for package in packages}
    for path in paths:
        if path.startswith("shared/"):
            parts = path.split("/")
            if len(parts) >= 2:
                affected.update(by_shared.get(parts[1], set()))
        for package in packages:
            prefix = f"{package.dir}/"
            if not path.startswith(prefix):
                continue
            relative = path[len(prefix) :]
            if not runtime_only or relative.startswith("root/") or relative in RUNTIME_NAMES:
                affected.add(package.id)
    return {"include": [asdict(package) for package in packages if package.id in affected]}


def git_file(repo: Path, revision: str, path: str) -> str:
    return run_git(repo, "show", f"{revision}:{path}")


def is_vaapi_digest_only(repo: Path, base: str, head: str, paths: list[str]) -> bool:
    dockerfile = "mods/plex/vaapi-amdgpu-mod/Dockerfile"
    if paths != [dockerfile]:
        return False
    before = git_file(repo, base, dockerfile)
    after = git_file(repo, head, dockerfile)
    pattern = re.compile(r"(\balpine:edge)(?:@sha256:[0-9a-f]{64})?")
    return (
        len(pattern.findall(before)) == 1
        and len(pattern.findall(after)) == 1
        and pattern.sub(r"\1@DIGEST", before) == pattern.sub(r"\1@DIGEST", after)
        and before != after
    )


def validate_pr(
    repo: Path,
    base: str,
    head: str,
    title: str,
    body: str,
    head_ref: str,
    head_repo: str,
    repository: str,
    author: str,
    expected_release_author: str,
) -> None:
    paths = sorted(changed_files(repo, base, head))
    shared_markers(repo, write=False)
    messages = run_git(repo, "log", "--format=%B", f"{base}..{head}")
    if re.search(r"(?im)^Release-As:\s*", f"{title}\n{body}\n{messages}"):
        raise ReleaseError("Release-As overrides are forbidden")

    if head_ref == RELEASE_BRANCH:
        if head_repo != repository:
            raise ReleaseError("the Release Please PR must come from this repository")
        if not expected_release_author or author != expected_release_author:
            raise ReleaseError(
                "the Release Please PR author does not match repository variable RELEASE_APP_LOGIN"
            )
        unexpected = [path for path in paths if not RELEASE_PR_FILES.fullmatch(path)]
        if unexpected:
            raise ReleaseError("Release Please PR contains unexpected files: " + ", ".join(unexpected))
        if ".release-please-manifest.json" not in paths:
            raise ReleaseError("Release Please PR did not update the manifest")
        return

    match = CONVENTIONAL.fullmatch(title)
    if not match:
        raise ReleaseError("pull request title is not an allowed Conventional Commit subject")
    commit_type = match.group("type")
    breaking = bool(match.group("breaking")) or bool(
        re.search(r"(?im)^BREAKING(?: |-)?CHANGE:\s*\S", body)
    )
    releasable = commit_type in {"feat", "fix"} or breaking
    packages = discover_packages(repo)
    runtime = runtime_packages(repo, packages, paths)
    relevant = runtime | signal_packages(packages, paths) | bootstrap_packages(
        repo, packages, base, head
    )
    routed = routed_packages(packages, paths)
    if releasable:
        if not relevant:
            raise ReleaseError("releasable PR has no runtime or audited artifact change")
        accidental = sorted(routed - relevant)
        if accidental:
            raise ReleaseError(
                "releasable PR would bump packages with metadata-only changes: " + ", ".join(accidental)
            )
    elif runtime:
        if commit_type == "chore" and is_vaapi_digest_only(repo, base, head, paths):
            return
        raise ReleaseError(
            "runtime changes require fix, feat, or breaking release intent: "
            + ", ".join(sorted(runtime))
        )


def tag_exists(repo: Path, tag: str) -> bool:
    return bool(run_git(repo, "rev-parse", "--verify", f"refs/tags/{tag}", check=False))


def previous_tag(repo: Path, package_id: str, current: str) -> str:
    tags = run_git(repo, "tag", "--list", f"{package_id}/v*", "--sort=-v:refname").splitlines()
    for index, tag in enumerate(tags):
        if tag == current:
            return tags[index + 1] if index + 1 < len(tags) else ""
    return ""


def candidate_from_tag(repo: Path, package: Package, tag: str, owner: str) -> tuple[str, str]:
    candidate_path = f"{package.dir}/{VAAPI_CANDIDATE}"
    candidate_exists = subprocess.run(
        ["git", "cat-file", "-e", f"{tag}:{candidate_path}"], cwd=repo
    )
    if candidate_exists.returncode:
        return "", ""
    previous = previous_tag(repo, package.id, tag)
    if previous:
        unchanged = subprocess.run(
            ["git", "diff", "--quiet", previous, tag, "--", candidate_path], cwd=repo
        )
        if unchanged.returncode == 0:
            return "", ""
    try:
        candidate = json.loads(git_file(repo, tag, candidate_path))
    except json.JSONDecodeError as error:
        raise ReleaseError(f"{candidate_path} is invalid JSON at {tag}: {error}") from error
    required = {"fingerprint", "ref", "digest", "source_sha"}
    if not isinstance(candidate, dict) or set(candidate) != required:
        raise ReleaseError(f"{candidate_path} must contain exactly {', '.join(sorted(required))}")
    fingerprint = candidate["fingerprint"]
    reference = candidate["ref"]
    digest = candidate["digest"]
    source_sha = candidate["source_sha"]
    if not isinstance(fingerprint, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", fingerprint):
        raise ReleaseError("VAAPI candidate fingerprint is invalid")
    expected_ref = f"ghcr.io/{owner}/{package.id}:candidate-vaapi-"
    if not isinstance(reference, str) or not reference.startswith(expected_ref) or "@" in reference:
        raise ReleaseError("VAAPI candidate ref is invalid")
    if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ReleaseError("VAAPI candidate digest is invalid")
    if not isinstance(source_sha, str) or not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ReleaseError("VAAPI candidate source_sha is invalid")
    ancestor = subprocess.run(["git", "merge-base", "--is-ancestor", source_sha, tag], cwd=repo)
    if ancestor.returncode:
        raise ReleaseError("VAAPI candidate source is not an ancestor of the release tag")
    fingerprint_path = f"{package.dir}/{VAAPI_FINGERPRINT}"
    fingerprint_data = json.loads(git_file(repo, tag, fingerprint_path))
    if fingerprint_data.get("fingerprint") != fingerprint:
        raise ReleaseError("VAAPI candidate does not match the recorded fingerprint")
    runtime_paths = [
        f"{package.dir}/Dockerfile",
        f"{package.dir}/PLATFORMS",
        f"{package.dir}/root",
        *[f"shared/{component}" for component in sorted(shared_inputs(repo, package))],
    ]
    unchanged = subprocess.run(
        ["git", "diff", "--quiet", source_sha, tag, "--", *runtime_paths], cwd=repo
    )
    if unchanged.returncode:
        raise ReleaseError("VAAPI runtime changed after the reviewed candidate was built")
    return reference, digest


def release_matrix(repo: Path, releases_path: Path, owner: str) -> dict[str, Any]:
    data = json.loads(releases_path.read_text(encoding="utf-8"))
    releases: list[Any] = []
    for item in data:
        releases.extend(item if isinstance(item, list) else [item])
    packages = {package.id: package for package in discover_packages(repo)}
    include: list[dict[str, Any]] = []
    seen: set[str] = set()
    for release in releases:
        if not isinstance(release, dict) or release.get("draft") is not True:
            continue
        tag = release.get("tag_name", "")
        match = re.fullmatch(
            r"(.+)/v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))", tag
        )
        if not match or match.group(1) not in packages:
            continue
        if tag in seen:
            raise ReleaseError(f"duplicate draft release for {tag}")
        seen.add(tag)
        package = packages[match.group(1)]
        version = match.group(2)
        if not tag_exists(repo, tag):
            raise ReleaseError(f"draft release tag is missing locally: {tag}")
        if git_file(repo, tag, f"{package.dir}/VERSION").strip() != version:
            raise ReleaseError(f"{tag} does not match {package.dir}/VERSION")
        source_sha = run_git(repo, "rev-list", "-n", "1", tag)
        candidate_ref, candidate_digest = candidate_from_tag(repo, package, tag, owner)
        item = asdict(package)
        item.update(
            {
                "version": version,
                "tag": tag,
                "source_sha": source_sha,
                "candidate_ref": candidate_ref,
                "candidate_digest": candidate_digest,
            }
        )
        include.append(item)
    include.sort(key=lambda item: (item["id"], item["version"]))
    return {"include": include}


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--repo", type=Path, default=Path.cwd())
    commands = result.add_subparsers(dest="command", required=True)
    commands.add_parser("packages")
    affected = commands.add_parser("affected")
    affected.add_argument("--base", required=True)
    affected.add_argument("--head", required=True)
    affected.add_argument("--runtime-only", action="store_true")
    markers = commands.add_parser("shared-markers")
    markers.add_argument("--write", action="store_true")
    validate = commands.add_parser("validate-pr")
    validate.add_argument("--base", required=True)
    validate.add_argument("--head", required=True)
    validate.add_argument("--title", required=True)
    validate.add_argument("--body", default="")
    validate.add_argument("--head-ref", required=True)
    validate.add_argument("--head-repo", required=True)
    validate.add_argument("--repository", required=True)
    validate.add_argument("--author", required=True)
    validate.add_argument("--expected-release-author", default="")
    drafts = commands.add_parser("release-matrix")
    drafts.add_argument("--releases", type=Path, required=True)
    drafts.add_argument("--owner", required=True)
    return result


def main() -> int:
    arguments = parser().parse_args()
    repo = arguments.repo.resolve()
    try:
        if arguments.command == "packages":
            output: Any = [asdict(package) for package in discover_packages(repo)]
        elif arguments.command == "affected":
            output = affected_packages(repo, arguments.base, arguments.head, arguments.runtime_only)
        elif arguments.command == "shared-markers":
            output = {"changed": shared_markers(repo, arguments.write)}
        elif arguments.command == "validate-pr":
            validate_pr(
                repo,
                arguments.base,
                arguments.head,
                arguments.title,
                arguments.body,
                arguments.head_ref,
                arguments.head_repo,
                arguments.repository,
                arguments.author,
                arguments.expected_release_author,
            )
            print("pull request release contract is valid")
            return 0
        elif arguments.command == "release-matrix":
            output = release_matrix(repo, arguments.releases, arguments.owner.lower())
        else:
            raise AssertionError(arguments.command)
        print(json.dumps(output, indent=2, sort_keys=True))
        return 0
    except (OSError, ReleaseError, json.JSONDecodeError) as error:
        print(f"release error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
