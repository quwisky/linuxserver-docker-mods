#!/usr/bin/env bash
# Validate package identity and the single, master-only CI topology.
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

MODS_DIR="${MODS_DIR:-mods}"
WF_DIR="${WF_DIR:-.github/workflows}"
rc=0

err() { printf '::error::%s\n' "$*"; }

check_verifier_credentials() {
    local workflow="$1"

    awk -v workflow="${workflow}" '
        function check_step() {
            if (!invokes_verifier) {
                return
            }
            if (!has_user) {
                printf "::error::%s verifier step %s is missing GH_USER.\n", workflow, step
                failed = 1
            }
            if (!has_pass) {
                printf "::error::%s verifier step %s is missing GH_PASS.\n", workflow, step
                failed = 1
            }
        }

        /^      - (name|uses):/ {
            check_step()
            step = $0
            sub(/^      - /, "", step)
            invokes_verifier = 0
            has_user = 0
            has_pass = 0
        }
        index($0, ".trusted/ci/verify-published-mod.sh") { invokes_verifier = 1 }
        /^          GH_USER: \$\{\{ github\.actor \}\}$/ { has_user = 1 }
        /^          GH_PASS: \$\{\{ secrets\.GITHUB_TOKEN \}\}$/ { has_pass = 1 }

        END {
            check_step()
            exit failed
        }
    ' "${workflow}"
}

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
    edge="${WF_DIR}/edge.yml"
    test_publisher="${WF_DIR}/test-image.yml"
    release_please="${WF_DIR}/release-please.yml"
    release_publisher="${WF_DIR}/publish-releases.yml"
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
    if [[ ! -f ${edge} ]]; then
        err "${edge} is missing; trusted master commits could not publish edge images."
        rc=1
    fi
    if [[ ! -f ${test_publisher} ]]; then
        err "${test_publisher} is missing; maintainers could not request test images."
        rc=1
    fi
    if [[ ! -f ${release_please} ]]; then
        err "${release_please} is missing; package releases could not be planned."
        rc=1
    fi
    if [[ ! -f ${release_publisher} ]]; then
        err "${release_publisher} is missing; draft releases could not be completed."
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
        if grep -qF './.github/workflows/_mod-publish.yml' "${ci}"; then
            err "${ci} must not expose trusted publication to pull requests."
            rc=1
        fi
        if grep -qF 'secrets: inherit' "${ci}"; then
            err "${ci} must not pass repository secrets to pull-request jobs."
            rc=1
        fi
    fi
    if [[ -f ${edge} ]]; then
        grep -qF 'branches: [master]' "${edge}" || {
            err "${edge} is not restricted to master pushes."
            rc=1
        }
        grep -qF './.github/workflows/_mod-publish.yml' "${edge}" || {
            err "${edge} does not call the trusted publication workflow."
            rc=1
        }
    fi
    if [[ -f ${publisher} ]]; then
        for guard in 'path: .trusted' 'path: .source' 'context: .source' \
            '.trusted/ci/verify-published-mod.sh'; do
            grep -qF "${guard}" "${publisher}" || {
                err "${publisher} is missing trusted/source isolation guard: ${guard}"
                rc=1
            }
        done
        if ! check_verifier_credentials "${publisher}"; then
            rc=1
        fi
    fi
    if [[ -f ${release_please} ]]; then
        grep -qF 'googleapis/release-please-action@45996ed1f6d02564a971a2fa1b5860e934307cf7' \
            "${release_please}" || {
            err "${release_please} must pin the reviewed Release Please action commit."
            rc=1
        }
        if grep -qF 'workflow_dispatch:' "${release_please}"; then
            err "${release_please} must not expose a manual release bypass."
            rc=1
        fi
    fi
    if [[ -f ${release_publisher} ]]; then
        grep -qF 'workflow_run:' "${release_publisher}" || {
            err "${release_publisher} must load trusted publication code from master."
            rc=1
        }
        grep -qF './.github/workflows/_mod-publish.yml' "${release_publisher}" || {
            err "${release_publisher} does not call the trusted publication workflow."
            rc=1
        }
    fi
    if [[ -f ${test_publisher} ]]; then
        grep -qF 'repository_dispatch:' "${test_publisher}" || {
            err "${test_publisher} must load only from the default branch."
            rc=1
        }
        if grep -qF 'workflow_dispatch:' "${test_publisher}"; then
            err "${test_publisher} must not load privileged code from a selected ref."
            rc=1
        fi
        grep -qF 'python3 .trusted/ci/release.py --repo .source packages' "${test_publisher}" || {
            err "${test_publisher} must parse requested refs with trusted tooling."
            rc=1
        }
    fi
    if [[ ! -f release-please-config.json ]] || [[ ! -f .release-please-manifest.json ]]; then
        err "Release Please config and manifest must both exist."
        rc=1
    else
        for i in "${!ids[@]}"; do
            configured="$(jq -r --arg path "${paths[${i}]}" '.packages[$path].component // empty' \
                release-please-config.json)"
            if [[ ${configured} != "${ids[${i}]}" ]]; then
                err "release-please-config.json does not map ${paths[${i}]} to ${ids[${i}]}"
                rc=1
            fi
        done
        configured_count="$(jq '.packages | length' release-please-config.json)"
        if [[ ${configured_count} != "${#ids[@]}" ]]; then
            err "release-please-config.json has ${configured_count} packages, expected ${#ids[@]}."
            rc=1
        fi
        jq -e --argjson config "$(jq '.packages' release-please-config.json)" '
          type == "object"
          and all(to_entries[]; $config[.key] != null)
          and all(.[]; test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))
        ' .release-please-manifest.json >/dev/null || {
            err ".release-please-manifest.json contains an unknown package or invalid version."
            rc=1
        }
    fi
    for legacy in "${WF_DIR}/release-pr.yml" "${WF_DIR}/release.yml" \
        "${WF_DIR}/renovate-fragment.yml"; do
        if [[ -e ${legacy} ]]; then
            err "${legacy} belongs to the removed custom release planner."
            rc=1
        fi
    done
    for workflow in "${ci}" "${reusable}" "${publisher}" "${edge}" "${test_publisher}" \
        "${release_please}" "${release_publisher}"; do
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
