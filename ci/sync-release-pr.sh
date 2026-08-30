#!/usr/bin/env bash
# Keep the App-owned Release Please pull request mergeable with strict checks.
set -Eeuo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
REPOSITORY="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
OWNER="${REPOSITORY%%/*}"
TARGET_BRANCH="${TARGET_BRANCH:-master}"
RELEASE_BRANCH="${RELEASE_BRANCH:-release-please--branches--master}"

pulls="$(gh api --method GET "repos/${REPOSITORY}/pulls" \
    -f state=open -f base="${TARGET_BRANCH}" -f head="${OWNER}:${RELEASE_BRANCH}")"
number="$(jq -r '.[0].number // empty' <<<"${pulls}")"
if [[ -z ${number} ]]; then
    printf 'no open release pull request\n'
    exit 0
fi
head_sha="$(jq -er '.[0].head.sha' <<<"${pulls}")"
target="$(gh api "repos/${REPOSITORY}/commits/${TARGET_BRANCH}")"
base_sha="$(jq -er '.sha' <<<"${target}")"
comparison="$(gh api "repos/${REPOSITORY}/compare/${base_sha}...${head_sha}")"
behind_by="$(jq -er '.behind_by' <<<"${comparison}")"
[[ ${behind_by} =~ ^[0-9]+$ ]] || {
    printf 'GitHub returned an invalid behind count for release pull request #%s: %s\n' \
        "${number}" "${behind_by}" >&2
    exit 1
}

if ((behind_by == 0)); then
    printf 'release pull request #%s is current\n' "${number}"
    exit 0
fi

printf 'updating release pull request #%s (%s commit(s) behind)\n' "${number}" "${behind_by}"
response="$(gh api --method PUT "repos/${REPOSITORY}/pulls/${number}/update-branch" \
    -f expected_head_sha="${head_sha}")"
jq -er '.message' <<<"${response}"
