#!/usr/bin/env bash
# Validate package identity and the single, master-only CI topology.
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

MODS_DIR="${MODS_DIR:-mods}"
WF_DIR="${WF_DIR:-.github/workflows}"
rc=0

err() { printf '::error::%s\n' "$*"; }

ids=()
paths=()
for dockerfile in "${MODS_DIR}"/*/*/Dockerfile; do
    [[ -f ${dockerfile} ]] || continue
    directory="${dockerfile%/Dockerfile}"
    mod="$(basename "${directory}")"
    app="$(basename "$(dirname "${directory}")")"
    id="${app}-${mod}"
    ids+=("${id}")
    paths+=("${directory}")

    if [[ ! -f ${directory}/VERSION ]] ||
        ! grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' "${directory}/VERSION"; then
        err "${directory}/VERSION must contain one plain SemVer version."
        rc=1
    fi
    if [[ ! -f ${directory}/CHANGELOG.md ]] || ! grep -q '^# Changelog$' "${directory}/CHANGELOG.md"; then
        err "${directory}/CHANGELOG.md must begin with '# Changelog'."
        rc=1
    fi
done

for i in "${!ids[@]}"; do
    for j in "${!ids[@]}"; do
        ((j > i)) || continue
        if [[ ${ids[${i}]} == "${ids[${j}]}" ]]; then
            err "${paths[${i}]} and ${paths[${j}]} both compose to package id '${ids[${i}]}'."
            rc=1
        fi
    done
done

# Scratch scaffolds validate package metadata only. The repository itself has
# one central workflow; generating a caller per mod is deliberately gone.
if [[ ${WF_DIR} == .github/workflows ]]; then
    ci="${WF_DIR}/ci.yml"
    reusable="${WF_DIR}/_mod-ci.yml"
    publisher="${WF_DIR}/_mod-publish.yml"
    if [[ ! -f ${ci} ]]; then
        err "${ci} is missing; CI would have no aggregate required check."
        rc=1
    fi
    if [[ ! -f ${reusable} ]]; then
        err "${reusable} is missing; affected packages could not be tested."
        rc=1
    fi
    if [[ ! -f ${publisher} ]]; then
        err "${publisher} is missing; trusted candidates could not be published."
        rc=1
    fi
    for legacy in "${WF_DIR}"/mod-*.yml; do
        [[ -e ${legacy} ]] || continue
        err "${legacy} is a legacy per-mod caller; ci.yml owns package fan-out now."
        rc=1
    done
    if [[ -f ${ci} ]]; then
        grep -qF 'python3 ci/release.py affected' "${ci}" || {
            err "${ci} does not derive its affected-package matrix from ci/release.py."
            rc=1
        }
        grep -qF 'name: CI / required' "${ci}" || {
            err "${ci} does not expose the stable 'CI / required' gate."
            rc=1
        }
        grep -qF './.github/workflows/_mod-ci.yml' "${ci}" || {
            err "${ci} does not call the shared mod workflow."
            rc=1
        }
        grep -qF './.github/workflows/_mod-publish.yml' "${ci}" || {
            err "${ci} does not call the trusted publication workflow."
            rc=1
        }
    fi
    for workflow in "${ci}" "${reusable}" "${publisher}"; do
        [[ -f ${workflow} ]] || continue
        if grep -Eq 'refs/heads/develop|(^|[^A-Za-z])nightly([^A-Za-z]|$)' "${workflow}"; then
            err "${workflow} still references the removed develop/nightly channel."
            rc=1
        fi
        if grep -qE '^[[:space:]]+schedule:' "${workflow}"; then
            err "${workflow} has a schedule; ordinary mod CI is event-driven only."
            rc=1
        fi
    done
fi

if ((rc == 0)); then
    printf '**** %d independently versioned mod(s), one aggregate CI workflow ****\n' "${#ids[@]}"
    for i in "${!ids[@]}"; do
        printf '  %s -> ghcr.io/<owner>/%s\n' "${paths[${i}]}" "${ids[${i}]}"
    done
fi
exit "${rc}"
