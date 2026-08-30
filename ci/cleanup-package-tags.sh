#!/usr/bin/env bash
# Event-driven GHCR retention for test and unreleased candidate tags.
set -Eeuo pipefail

usage() {
    printf 'usage: ci/cleanup-package-tags.sh <package> <test|candidates> <keep>\n' >&2
    exit 2
}

[[ $# -eq 3 ]] || usage
: "${GH_TOKEN:?GH_TOKEN is required}"
PACKAGE="$1"
MODE="$2"
KEEP="$3"
[[ ${PACKAGE} =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || usage
[[ ${KEEP} =~ ^[0-9]+$ ]] || usage
case "${MODE}" in
    test) pattern='^test-[0-9a-f]{12}$' ;;
    candidates) pattern='^(sha-[0-9a-f]{40}|candidate-vaapi-[0-9a-f]{12}-[0-9]+)$' ;;
    *) usage ;;
esac

OWNER="${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER is required}"
owner_type="$(gh api "users/${OWNER}" --jq .type)"
case "${owner_type}" in
    Organization) endpoint="orgs/${OWNER}/packages/container/${PACKAGE}/versions" ;;
    User) endpoint="users/${OWNER}/packages/container/${PACKAGE}/versions" ;;
    *) printf 'unsupported repository owner type: %s\n' "${owner_type}" >&2; exit 1 ;;
esac

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
gh api --paginate --slurp "${endpoint}?per_page=100" | jq 'add | sort_by(.updated_at) | reverse' >"${scratch}/versions.json"

mapfile -t removable < <(jq -r --arg pattern "${pattern}" --argjson keep "${KEEP}" '
  [ .[]
    | . as $version
    | (.metadata.container.tags // []) as $tags
    | select(($tags | any(test($pattern))) and ($tags | all(test($pattern))))
  ]
  | .[$keep:]
  | .[]
  | [.id, (.metadata.container.tags | join(","))] | @tsv
' "${scratch}/versions.json")

for entry in "${removable[@]}"; do
    id="${entry%%$'\t'*}"
    tags="${entry#*$'\t'}"
    printf 'deleting %s version %s (%s)\n' "${PACKAGE}" "${id}" "${tags}"
    gh api --method DELETE "${endpoint}/${id}"
done
printf 'retained newest %s %s-only version(s) for %s\n' "${KEEP}" "${MODE}" "${PACKAGE}"
