#!/usr/bin/env python3
"""Release metadata and affected-package orchestration for Docker Mods.

The command intentionally uses only Python's standard library.  GitHub Actions,
maintainer workstations, and the release GitHub App all exercise the same public
CLI instead of reimplementing package discovery or SemVer policy in YAML.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
from datetime import date
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
from typing import Any, Iterable


DEFAULT_PLATFORMS = "linux/amd64,linux/arm64"
BUMP_RANK = {"none": 0, "patch": 1, "minor": 2, "major": 3}
SHARED_COPY = re.compile(r"(?:^|\s)(shared/[A-Za-z0-9._/-]+)")
SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
RUNTIME_NAMES = {"Dockerfile", "PLATFORMS"}
PLAN_FIELDS = {
    "app",
    "mod",
    "id",
    "dir",
    "platforms",
    "previous_version",
    "version",
    "bump",
    "tag",
    "notes",
    "candidate_ref",
    "candidate_digest",
}


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


@dataclass(frozen=True)
class Fragment:
    path: Path
    summary: str
    packages: dict[str, str]
    shared: dict[str, str]
    candidates: dict[str, dict[str, str]]


def run_git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
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
        packages.append(
            Package(
                app=app,
                mod=mod,
                id=package_id,
                dir=relative,
                platforms=platforms,
                version=version,
            )
        )
    return packages


def shared_inputs(repo: Path, package: Package) -> set[str]:
    dockerfile = repo / package.dir / "Dockerfile"
    result: set[str] = set()
    for line in dockerfile.read_text(encoding="utf-8").splitlines():
        stripped = line.lstrip()
        if not stripped.startswith("COPY"):
            continue
        for match in SHARED_COPY.finditer(stripped):
            # A shared component is the first directory below shared/.  COPY
            # may name a file below it, but release fan-out belongs to the
            # component as a whole.
            parts = match.group(1).split("/")
            if len(parts) >= 2:
                result.add(parts[1])
    return result


def consumers(repo: Path, packages: Iterable[Package]) -> dict[str, set[str]]:
    result: dict[str, set[str]] = {}
    for package in packages:
        for shared in shared_inputs(repo, package):
            result.setdefault(shared, set()).add(package.id)
    return result


def changed_files(repo: Path, base: str, head: str) -> list[str]:
    output = run_git(repo, "diff", "--name-only", "--diff-filter=ACDMRTUXB", base, head)
    return [line for line in output.splitlines() if line]


def fragments_in(repo: Path, paths: Iterable[str] | None = None) -> list[Fragment]:
    if paths is None:
        candidates = sorted((repo / ".changes").glob("*.json"))
    else:
        candidates = [repo / path for path in paths if path.startswith(".changes/") and path.endswith(".json")]
    fragments: list[Fragment] = []
    for path in candidates:
        if not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            raise ReleaseError(f"{path.relative_to(repo)} is not valid JSON: {error}") from error
        if not isinstance(data, dict):
            raise ReleaseError(f"{path.relative_to(repo)} must contain a JSON object")
        allowed = {"summary", "packages", "shared", "candidates"}
        unknown = sorted(set(data) - allowed)
        if unknown:
            raise ReleaseError(f"{path.relative_to(repo)} has unknown keys: {', '.join(unknown)}")
        summary = data.get("summary")
        if not isinstance(summary, str) or not summary.strip():
            raise ReleaseError(f"{path.relative_to(repo)} needs a non-empty summary")
        package_bumps = validate_bump_map(path, "packages", data.get("packages", {}))
        shared_bumps = validate_bump_map(path, "shared", data.get("shared", {}))
        raw_candidates = data.get("candidates", {})
        if not isinstance(raw_candidates, dict):
            raise ReleaseError(f"{path.relative_to(repo)} candidates must be an object")
        normalized_candidates: dict[str, dict[str, str]] = {}
        for package_id, candidate in raw_candidates.items():
            if not isinstance(candidate, dict):
                raise ReleaseError(f"{path.relative_to(repo)} candidate for {package_id} must be an object")
            if set(candidate) != {"ref", "digest"}:
                raise ReleaseError(
                    f"{path.relative_to(repo)} candidate for {package_id} needs exactly ref and digest"
                )
            ref = candidate["ref"]
            digest = candidate["digest"]
            if not isinstance(ref, str) or not ref:
                raise ReleaseError(f"{path.relative_to(repo)} candidate ref for {package_id} is empty")
            if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
                raise ReleaseError(f"{path.relative_to(repo)} candidate digest for {package_id} is invalid")
            normalized_candidates[package_id] = {"ref": ref, "digest": digest}
        if not package_bumps and not shared_bumps:
            raise ReleaseError(f"{path.relative_to(repo)} names no package or shared component")
        fragments.append(
            Fragment(
                path=path,
                summary=summary.strip(),
                packages=package_bumps,
                shared=shared_bumps,
                candidates=normalized_candidates,
            )
        )
    return fragments


def validate_bump_map(path: Path, field: str, value: Any) -> dict[str, str]:
    if not isinstance(value, dict):
        raise ReleaseError(f"{path} {field} must be an object")
    result: dict[str, str] = {}
    for name, bump in value.items():
        if not isinstance(name, str) or not name:
            raise ReleaseError(f"{path} {field} contains an empty name")
        if bump not in BUMP_RANK:
            raise ReleaseError(f"{path} {field}.{name} must be none, patch, minor, or major")
        result[name] = bump
    return result


def expand_fragments(
    repo: Path, packages: list[Package], fragments: Iterable[Fragment]
) -> tuple[dict[str, str], dict[str, list[str]], dict[str, dict[str, str]]]:
    package_by_id = {package.id: package for package in packages}
    by_shared = consumers(repo, packages)
    bumps: dict[str, str] = {}
    notes: dict[str, list[str]] = {}
    candidates: dict[str, dict[str, str]] = {}

    for fragment in fragments:
        expanded: dict[str, str] = {}
        for shared, bump in fragment.shared.items():
            if shared not in by_shared:
                raise ReleaseError(f"{fragment.path.name} names unknown or unused shared component {shared}")
            for package_id in by_shared[shared]:
                existing = expanded.get(package_id, "none")
                if BUMP_RANK[bump] > BUMP_RANK[existing]:
                    expanded[package_id] = bump
        for package_id, bump in fragment.packages.items():
            if package_id not in package_by_id:
                raise ReleaseError(f"{fragment.path.name} names unknown package {package_id}")
            inherited = expanded.get(package_id)
            if inherited and BUMP_RANK[bump] < BUMP_RANK[inherited]:
                raise ReleaseError(
                    f"{fragment.path.name} lowers {package_id} from shared {inherited} to {bump}"
                )
            expanded[package_id] = bump
        for package_id, bump in expanded.items():
            previous = bumps.get(package_id, "none")
            if previous != "none" and bump == "none":
                raise ReleaseError(f"{package_id} has both release and release:none intent")
            if previous == "none" and bump != "none" or BUMP_RANK[bump] > BUMP_RANK[previous]:
                bumps[package_id] = bump
            else:
                bumps.setdefault(package_id, bump)
            notes.setdefault(package_id, []).append(fragment.summary)
        for package_id, candidate in fragment.candidates.items():
            if package_id not in expanded:
                raise ReleaseError(f"{fragment.path.name} has a candidate for unaffected {package_id}")
            if expanded[package_id] == "none":
                raise ReleaseError(f"{fragment.path.name} cannot attach a candidate to release:none")
            if package_id in candidates:
                raise ReleaseError(f"multiple candidate artifacts supplied for {package_id}")
            candidates[package_id] = candidate
    for package_id in candidates:
        if len(notes[package_id]) != 1:
            raise ReleaseError(
                f"{package_id} has a reviewed candidate plus another release intent; "
                "rebuild one candidate from the combined change"
            )
    return bumps, notes, candidates


def bump_version(version: str, bump: str) -> str:
    match = SEMVER.fullmatch(version)
    if not match:
        raise ReleaseError(f"invalid SemVer version {version}")
    major, minor, patch = (int(value) for value in match.groups())
    if bump == "patch":
        patch += 1
    elif bump == "minor":
        minor += 1
        patch = 0
    elif bump == "major":
        major += 1
        minor = 0
        patch = 0
    else:
        raise ReleaseError(f"cannot version-bump {bump}")
    return f"{major}.{minor}.{patch}"


def build_plan(repo: Path) -> dict[str, Any]:
    packages = discover_packages(repo)
    bumps, notes, candidates = expand_fragments(repo, packages, fragments_in(repo))
    entries: list[dict[str, Any]] = []
    for package in packages:
        bump = bumps.get(package.id, "none")
        if bump == "none":
            continue
        version = bump_version(package.version, bump)
        entry: dict[str, Any] = {
            **asdict(package),
            "previous_version": package.version,
            "version": version,
            "bump": bump,
            "tag": f"{package.id}/v{version}",
            "notes": notes[package.id],
            "candidate_ref": "",
            "candidate_digest": "",
        }
        if package.id in candidates:
            entry["candidate_ref"] = candidates[package.id]["ref"]
            entry["candidate_digest"] = candidates[package.id]["digest"]
        entries.append(entry)
    source_sha = ""
    if (repo / ".git").exists():
        try:
            source_sha = run_git(repo, "rev-parse", "HEAD")
        except ReleaseError:
            # A freshly scaffolded repository can prepare its first release
            # metadata before its initial commit.  Real release automation is
            # always on a commit, but package planning itself does not require
            # one.
            source_sha = ""
    return {"source_sha": source_sha, "packages": entries}


def read_plan(repo: Path) -> dict[str, Any]:
    path = repo / ".release/plan.json"
    try:
        plan = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ReleaseError(".release/plan.json is missing") from error
    except json.JSONDecodeError as error:
        raise ReleaseError(f".release/plan.json is not valid JSON: {error}") from error
    if not isinstance(plan, dict) or set(plan) != {"source_sha", "packages"}:
        raise ReleaseError("release plan needs exactly source_sha and packages")
    if not isinstance(plan["source_sha"], str) or not re.fullmatch(
        r"[0-9a-f]{40}", plan["source_sha"]
    ):
        raise ReleaseError("release plan source_sha must be a full lowercase commit SHA")
    if not isinstance(plan["packages"], list):
        raise ReleaseError("release plan packages must be an array")
    return plan


def validate_plan_structure(repo: Path, plan: dict[str, Any], owner: str = "") -> None:
    packages = {package.id: package for package in discover_packages(repo)}
    seen: set[str] = set()
    for index, entry in enumerate(plan["packages"]):
        label = f"release plan package {index}"
        if not isinstance(entry, dict) or set(entry) != PLAN_FIELDS:
            raise ReleaseError(f"{label} has an invalid field set")
        package_id = entry["id"]
        if not isinstance(package_id, str) or package_id not in packages:
            raise ReleaseError(f"{label} names unknown package {package_id}")
        if package_id in seen:
            raise ReleaseError(f"release plan repeats package {package_id}")
        seen.add(package_id)
        package = packages[package_id]
        for field in ("app", "mod", "dir", "platforms"):
            if entry[field] != getattr(package, field):
                raise ReleaseError(f"release plan {package_id} has incorrect {field}")
        previous = entry["previous_version"]
        version = entry["version"]
        bump = entry["bump"]
        if not isinstance(previous, str) or not SEMVER.fullmatch(previous):
            raise ReleaseError(f"release plan {package_id} has invalid previous_version")
        if bump not in {"patch", "minor", "major"}:
            raise ReleaseError(f"release plan {package_id} has invalid bump")
        if version != bump_version(previous, bump) or version != package.version:
            raise ReleaseError(f"release plan {package_id} version does not match its bump and VERSION")
        if entry["tag"] != f"{package_id}/v{version}":
            raise ReleaseError(f"release plan {package_id} has an invalid Git tag")
        notes = entry["notes"]
        if not isinstance(notes, list) or not notes or not all(
            isinstance(note, str) and note.strip() for note in notes
        ):
            raise ReleaseError(f"release plan {package_id} needs non-empty notes")
        candidate_ref = entry["candidate_ref"]
        candidate_digest = entry["candidate_digest"]
        if not isinstance(candidate_ref, str) or not isinstance(candidate_digest, str):
            raise ReleaseError(f"release plan {package_id} candidate fields must be strings")
        if bool(candidate_ref) != bool(candidate_digest):
            raise ReleaseError(f"release plan {package_id} has an incomplete candidate")
        if candidate_ref:
            prefix = f"ghcr.io/{owner}/{package_id}:" if owner else "ghcr.io/"
            if not candidate_ref.startswith(prefix) or "@" in candidate_ref:
                raise ReleaseError(f"release plan {package_id} has an invalid candidate ref")
            if not owner and f"/{package_id}:" not in candidate_ref:
                raise ReleaseError(f"release plan {package_id} candidate targets another package")
            if not re.fullmatch(r"sha256:[0-9a-f]{64}", candidate_digest):
                raise ReleaseError(f"release plan {package_id} has an invalid candidate digest")


def verify_plan(repo: Path, base: str = "", owner: str = "") -> None:
    plan = read_plan(repo)
    validate_plan_structure(repo, plan, owner.lower())
    if not base:
        return
    resolved_base = run_git(repo, "rev-parse", "--verify", f"{base}^{{commit}}")
    archive = subprocess.run(
        ["git", "archive", "--format=tar", resolved_base],
        cwd=repo,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if archive.returncode:
        raise ReleaseError(archive.stderr.decode().strip() or "git archive failed")
    with tempfile.TemporaryDirectory() as temporary:
        snapshot = Path(temporary)
        with tarfile.open(fileobj=io.BytesIO(archive.stdout), mode="r:") as tar:
            tar.extractall(snapshot, filter="data")
        expected = build_plan(snapshot)
    expected["source_sha"] = resolved_base
    if plan != expected:
        raise ReleaseError("release plan does not exactly match the base branch change fragments")


def affected_packages(repo: Path, base: str, head: str) -> dict[str, list[dict[str, Any]]]:
    packages = discover_packages(repo)
    package_by_dir = {package.dir: package for package in packages}
    by_shared = consumers(repo, packages)
    changed = changed_files(repo, base, head)
    affected: set[str] = set()
    all_packages = False
    global_ci = {
        ".dockerignore",
        ".github/workflows/_mod-ci.yml",
        ".github/workflows/ci.yml",
        "ci/release.py",
        "ci/mod-inputs.sh",
        "ci/verify-published-mod.sh",
    }
    for path in changed:
        if path in global_ci or path.startswith("template/"):
            all_packages = True
        for directory, package in package_by_dir.items():
            if path == directory or path.startswith(f"{directory}/"):
                affected.add(package.id)
        if path.startswith("shared/"):
            parts = path.split("/")
            if len(parts) >= 2:
                affected.update(by_shared.get(parts[1], set()))
    if all_packages:
        affected = {package.id for package in packages}

    _, _, candidates = expand_fragments(repo, packages, fragments_in(repo))
    include: list[dict[str, Any]] = []
    for package in packages:
        if package.id not in affected:
            continue
        item = asdict(package)
        if package.id in candidates:
            item["candidate_ref"] = candidates[package.id]["ref"]
            item["candidate_digest"] = candidates[package.id]["digest"]
        else:
            item["candidate_ref"] = ""
            item["candidate_digest"] = ""
        include.append(item)
    return {"include": include}


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


def validate_release_intent(repo: Path, base: str, head: str) -> None:
    packages = discover_packages(repo)
    paths = changed_files(repo, base, head)
    changed_fragment_paths = [path for path in paths if path.startswith(".changes/")]
    fragments = fragments_in(repo, changed_fragment_paths)
    bumps, _, _ = expand_fragments(repo, packages, fragments)
    missing = sorted(runtime_packages(repo, packages, paths) - set(bumps))
    if missing:
        joined = "\n".join(f"{package_id} has runtime changes but no release intent" for package_id in missing)
        raise ReleaseError(joined)


def prepend_changelog(path: Path, version: str, notes: list[str]) -> None:
    existing = path.read_text(encoding="utf-8") if path.exists() else "# Changelog\n"
    if not existing.startswith("# Changelog"):
        raise ReleaseError(f"{path} must begin with '# Changelog'")
    header, _, rest = existing.partition("\n")
    entry = [f"## {version} - {date.today().isoformat()}", ""]
    entry.extend(f"- {note}" for note in notes)
    entry.append("")
    path.write_text(f"{header}\n\n" + "\n".join(entry) + rest.lstrip("\n"), encoding="utf-8")


def prepare(repo: Path) -> dict[str, Any]:
    plan = build_plan(repo)
    for item in plan["packages"]:
        directory = repo / item["dir"]
        (directory / "VERSION").write_text(f"{item['version']}\n", encoding="utf-8")
        prepend_changelog(directory / "CHANGELOG.md", item["version"], item["notes"])
    release_dir = repo / ".release"
    release_dir.mkdir(parents=True, exist_ok=True)
    (release_dir / "plan.json").write_text(
        json.dumps(plan, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    changes = repo / ".changes"
    if changes.is_dir():
        for fragment in changes.glob("*.json"):
            fragment.unlink()
    return plan


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--repo", type=Path, default=Path.cwd())
    subcommands = result.add_subparsers(dest="command", required=True)
    subcommands.add_parser("packages")
    for name in ("affected", "validate"):
        command = subcommands.add_parser(name)
        command.add_argument("--base", required=True)
        command.add_argument("--head", required=True)
    subcommands.add_parser("plan")
    subcommands.add_parser("prepare")
    verify = subcommands.add_parser("verify-plan")
    verify.add_argument("--base", default="")
    verify.add_argument("--owner", default="")
    return result


def main() -> int:
    arguments = parser().parse_args()
    repo = arguments.repo.resolve()
    try:
        if arguments.command == "packages":
            output: Any = [asdict(package) for package in discover_packages(repo)]
        elif arguments.command == "affected":
            output = affected_packages(repo, arguments.base, arguments.head)
        elif arguments.command == "validate":
            validate_release_intent(repo, arguments.base, arguments.head)
            print("release intent is valid")
            return 0
        elif arguments.command == "plan":
            output = build_plan(repo)
        elif arguments.command == "prepare":
            output = prepare(repo)
        elif arguments.command == "verify-plan":
            verify_plan(repo, arguments.base, arguments.owner)
            print("release plan is valid")
            return 0
        else:  # pragma: no cover - argparse enforces the command set.
            raise AssertionError(arguments.command)
        print(json.dumps(output, indent=None, sort_keys=True))
        return 0
    except ReleaseError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
