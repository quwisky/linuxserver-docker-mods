#!/usr/bin/env bash
# One-time, fail-closed migration away from develop/nightly.
set -Eeuo pipefail

usage() {
    printf 'usage: ci/cutover.sh [--execute]\n' >&2
    printf '  dry-run is the default; execution also requires CONFIRM=DELETE_NIGHTLY_AND_DEVELOP\n' >&2
    exit 2
}

EXECUTE=false
case "${1:-}" in
    '') ;;
    --execute) EXECUTE=true ;;
    *) usage ;;
esac
: "${GH_TOKEN:?GH_TOKEN is required}"
REPOSITORY="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
OWNER="${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER is required}"
if ${EXECUTE}; then
    [[ ${CONFIRM:-} == DELETE_NIGHTLY_AND_DEVELOP ]] || {
        printf 'refusing execution: confirmation is not DELETE_NIGHTLY_AND_DEVELOP\n' >&2
        exit 1
    }
fi

owner_type="$(gh api "users/${OWNER}" --jq .type)"
case "${owner_type}" in
    Organization) package_root="orgs/${OWNER}/packages/container" ;;
    User) package_root="users/${OWNER}/packages/container" ;;
    *) printf 'unsupported repository owner type: %s\n' "${owner_type}" >&2; exit 1 ;;
esac

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
targets="${scratch}/package-versions.tsv"
: >"${targets}"

printf '%s\n' 'Preflight: verified replacements'
while IFS=$'\t' read -r package version; do
    [[ ${version} != 0.0.0 ]] || {
        printf '%s has not completed its initial release\n' "${package}" >&2
        exit 1
    }
    is_draft="$(gh release view "${package}/v${version}" --json isDraft --jq .isDraft)"
    [[ ${is_draft} == false ]] || {
        printf '%s v%s is still a draft release\n' "${package}" "${version}" >&2
        exit 1
    }
    printf '  %s v%s\n' "${package}" "${version}"

    endpoint="${package_root}/${package}/versions"
    versions="${scratch}/${package}.json"
    gh api --paginate --slurp "${endpoint}?per_page=100" | jq 'add' >"${versions}"
    if jq -e '[.[] | (.metadata.container.tags // []) as $tags | select(
        ($tags | any(test("^nightly($|-)"))) and
        ($tags | any(test("^nightly($|-)") | not))
      )] | length > 0' "${versions}" >/dev/null; then
        printf '%s has a registry version mixing nightly and protected non-nightly tags; refusing cleanup\n' "${package}" >&2
        exit 1
    fi
    jq -r --arg package "${package}" '
      .[]
      | (.metadata.container.tags // []) as $tags
      | select(($tags | length) > 0 and ($tags | all(test("^nightly($|-)"))))
      | [$package, (.id | tostring), ($tags | join(","))] | @tsv
    ' "${versions}" >>"${targets}"
done < <(python3 ci/release.py packages | jq -r '.[] | [.id, .version] | @tsv')

printf '%s\n' 'Preflight: exact GHCR versions selected for deletion'
if [[ -s ${targets} ]]; then
    sed 's/^/  /' "${targets}"
else
    printf '%s\n' '  none (already clean)'
fi

if gh api "repos/${REPOSITORY}/branches/develop" >/dev/null 2>&1; then
    printf '%s\n' 'Preflight: develop branch exists and is selected for deletion'
else
    printf '%s\n' 'Preflight: develop branch is already absent'
fi

policies="${scratch}/policies.json"
gh api "repos/${REPOSITORY}/environments/github-pages/deployment-branch-policies" >"${policies}" 2>/dev/null ||
    printf '{"branch_policies":[]}\n' >"${policies}"
mapfile -t policy_ids < <(jq -r '.branch_policies[]? | select(.name == "develop") | .id' "${policies}")
printf 'Preflight: %d develop Pages policy target(s)\n' "${#policy_ids[@]}"

if ! ${EXECUTE}; then
    printf '%s\n' 'Dry run only. Re-run with --execute and the exact CONFIRM value after reviewing every target.'
    exit 0
fi

while IFS=$'\t' read -r package version_id tags; do
    [[ -n ${package} ]] || continue
    printf 'deleting %s version %s (%s)\n' "${package}" "${version_id}" "${tags}"
    gh api --method DELETE "${package_root}/${package}/versions/${version_id}"
done <"${targets}"

if gh api "repos/${REPOSITORY}/branches/develop" >/dev/null 2>&1; then
    gh api --method DELETE "repos/${REPOSITORY}/git/refs/heads/develop"
fi
for policy_id in "${policy_ids[@]}"; do
    gh api --method DELETE \
        "repos/${REPOSITORY}/environments/github-pages/deployment-branch-policies/${policy_id}"
done

# Read back every destructive target. A successful HTTP response is not enough
# evidence for a one-time cutover.
while IFS=$'\t' read -r package _ _; do
    [[ -n ${package} ]] || continue
    endpoint="${package_root}/${package}/versions"
    if gh api --paginate --slurp "${endpoint}?per_page=100" |
        jq -e 'add | any(.[]; (.metadata.container.tags // []) | any(test("^nightly($|-)")))' >/dev/null; then
        printf '%s still has a nightly tag after cleanup\n' "${package}" >&2
        exit 1
    fi
done <"${targets}"
if gh api "repos/${REPOSITORY}/branches/develop" >/dev/null 2>&1; then
    printf 'develop still exists after cleanup\n' >&2
    exit 1
fi
printf '%s\n' '**** cutover complete: nightly tags, develop, and its Pages policy are absent ****'
