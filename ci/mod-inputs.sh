#!/usr/bin/env bash
# Everything in the repo that a mod's image is built from.
#
#   ci/mod-inputs.sh mods/<app>/<mod>            # the paths, one per line
#   ci/mod-inputs.sh --hash mods/<app>/<mod>     # a 12-char hash of their content
#
# A mod used to be exactly its own directory, so `git rev-parse HEAD:mods/<app>/<mod>`
# was a complete content address for it. Since the build context moved to the
# repo root, a mod can also COPY a directory out of shared/ -- and then the mod
# directory alone is NOT a complete content address.
#
# That matters because the nightly publish is deduped on this hash: an unchanged
# hash resolves to a tag that already exists and the push is skipped. Hashing
# only the mod directory would mean a change to shared/ produced a genuinely
# different image that CI then refused to publish, silently, forever.
#
# The dependency list is read from the Dockerfile rather than configured
# anywhere, so it cannot drift from what the build actually copies.
#
# REF selects the commit to read (default HEAD), so this works on any checkout.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

HASH=0
if [[ ${1-} == "--hash" ]]; then
    HASH=1
    shift
fi

[[ $# -eq 1 ]] || {
    echo "usage: ci/mod-inputs.sh [--hash] mods/<app>/<mod>" >&2
    exit 2
}

DIR="${1%/}"
REF="${REF:-HEAD}"

[[ -f "${DIR}/Dockerfile" ]] || {
    echo "::error::${DIR}/Dockerfile does not exist" >&2
    exit 1
}

inputs=("${DIR}")
while IFS= read -r dep; do
    [[ -z ${dep} ]] && continue
    inputs+=("${dep}")
done < <(grep -E '^[[:space:]]*COPY' "${DIR}/Dockerfile" |
    grep -oE 'shared/[A-Za-z0-9._-]+' | sort -u)

if ((!HASH)); then
    printf '%s\n' "${inputs[@]}"
    exit 0
fi

# Combine the per-path tree hashes rather than hashing a tarball: git already
# content-addresses a directory, and including the path name means moving a
# shared directory changes the result even if its bytes did not.
for p in "${inputs[@]}"; do
    if ! git rev-parse --verify --quiet "${REF}:${p}" >/dev/null; then
        echo "::error::${p} is not present at ${REF}" >&2
        exit 1
    fi
    printf '%s %s\n' "$(git rev-parse "${REF}:${p}")" "${p}"
done | git hash-object --stdin | cut -c1-12
