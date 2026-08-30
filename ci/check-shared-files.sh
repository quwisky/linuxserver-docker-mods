#!/usr/bin/env bash
# The invariants that make shared/ safe.
#
#   ci/check-shared-files.sh
#
# A mod's build context is the repo root, so a Dockerfile can COPY a directory
# out of shared/ in addition to its own root/. That removes the need to duplicate
# a file per mod, and introduces three new ways to be quietly wrong:
#
#  1. A mod copies a shared/ directory that does not exist. The build fails
#     loudly, so this is only checked for completeness.
#
#  2. A shared/ directory nothing references. Harmless, but it is dead weight
#     that will rot, and it usually means a mod was deleted or renamed.
#
# It also keeps the older rule that two mods must not ship DIFFERENT content at
# the same container path. DOCKER_MODS applies several overlays to one container
# in order, so whichever is listed last silently wins and the other mod is
# subtly broken with nothing in the log to say so.
#
# This runs below the aggregate CI gate on every pull request and master push.
# Everything here is derived from the tree and the Dockerfiles rather than from a
# list kept somewhere, so it cannot drift from what the builds actually do.
#
# MODS_DIR can point elsewhere for testing. Affected-package fan-out is derived
# by ci/release.py from the same Dockerfile COPY statements.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

MODS_DIR="${MODS_DIR:-mods}"
SHARED_DIR="${SHARED_DIR:-shared}"
rc=0

err() { echo "::error::$*"; }

# Parallel arrays and no `declare -A`: this has to run on macOS, which still
# ships bash 3.2. Same constraint as ci/check-mod-workflows.sh.
used=() # shared/<dir> entries that some mod copies

for d in "${MODS_DIR}"/*/*/; do
    [[ -f "${d}Dockerfile" ]] || continue
    mod="$(basename "${d%/}")"
    app="$(basename "$(dirname "${d%/}")")"
    while IFS= read -r dep; do
        [[ -z ${dep} ]] && continue
        used+=("${dep}")

        if [[ ! -d ${dep} ]]; then
            err "${d}Dockerfile copies ${dep}, which does not exist."
            rc=1
            continue
        fi

    done < <(ci/mod-inputs.sh "${MODS_DIR}/${app}/${mod}" | grep -v "^${MODS_DIR}/")
done

# Orphans: a shared directory nothing copies.
if [[ -d ${SHARED_DIR} ]]; then
    for s in "${SHARED_DIR}"/*/; do
        [[ -d ${s} ]] || continue
        name="${s%/}"
        found=0
        for u in "${used[@]:-}"; do
            [[ ${u} == "${name}" ]] && found=1 && break
        done
        if ((!found)); then
            err "${name} is not copied by any mod's Dockerfile."
            echo "       either a mod should be using it, or it should be deleted."
            rc=1
        fi
    done
fi

# Two mods must not ship different content at one container path.
paths=()
owners=()
while IFS= read -r f; do
    rest="${f#"${MODS_DIR}"/}"
    app="${rest%%/*}"
    rest="${rest#*/}"
    mod="${rest%%/*}"
    rest="${rest#*/}"
    [[ ${rest} == root/* ]] || continue
    paths+=("${rest#root/}")
    owners+=("${MODS_DIR}/${app}/${mod}")
done < <(find "${MODS_DIR}" -mindepth 4 -path "*/root/*" \( -type f -o -type l \) | sort)

if ((${#paths[@]})); then
    while IFS= read -r p; do
        [[ -z ${p} ]] && continue
        group=()
        for i in "${!paths[@]}"; do
            [[ ${paths[${i}]} == "${p}" ]] || continue
            group+=("${owners[${i}]}")
        done
        ref="${group[0]}/root/${p}"
        for owner in "${group[@]:1}"; do
            other="${owner}/root/${p}"
            if [[ -L ${ref} || -L ${other} ]]; then
                if [[ $(readlink "${ref}" 2>/dev/null) != $(readlink "${other}" 2>/dev/null) ]]; then
                    err "/${p} is a symlink in one of ${group[0]} / ${owner} and not the other, or points elsewhere."
                    rc=1
                fi
            elif ! cmp -s "${ref}" "${other}"; then
                err "/${p} differs between ${group[0]} and ${owner}."
                echo "       two mods applied to one container would fight over it; move it to ${SHARED_DIR}/ instead."
                rc=1
            fi
        done
    done < <(printf '%s\n' "${paths[@]}" | sort | uniq -d)
fi

if ((rc == 0)); then
    if ((${#used[@]})); then
        echo "**** shared/ is consistent ****"
        printf '%s\n' "${used[@]}" | sort -u | sed 's/^/  /'
    else
        echo "**** no mod uses shared/; nothing to check ****"
    fi
fi
exit $rc
