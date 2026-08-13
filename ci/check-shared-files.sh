#!/usr/bin/env bash
# Any file that more than one mod overlays at the SAME container path must be
# byte-identical in every mod that ships it.
#
#   ci/check-shared-files.sh
#
# Two reasons this is a rule rather than a preference:
#
#  1. Correctness. A mod is a filesystem overlay, and DOCKER_MODS applies several
#     of them to one container in order. Two mods shipping different content at
#     one path means whichever is listed last silently wins, and the loser's mod
#     is subtly broken with nothing in the log to say so.
#
#  2. Drift. Mods are independent single-layer images built with `FROM scratch` +
#     `COPY root/ /` from their own directory as build context, so there is no
#     cross-mod include mechanism -- genuinely shared logic has to be duplicated.
#     Duplication is fine as long as it cannot rot, and this is what stops it.
#     `netns-watchdog.sh` is the current case.
#
# This runs from repo.yml, which has NO paths filter, so it fires on every push.
# That is the whole point: the per-mod workflows only run when their own
# directory changes, so a commit touching one copy and not the other would
# otherwise sail through green -- which is exactly the failure this risks.
#
# The set of shared files is derived from the tree rather than listed here. A
# hardcoded list is one more thing that drifts, and the repo's convention is that
# the directory layout is the single source of truth.
#
# MODS_DIR can point elsewhere for testing.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

MODS_DIR="${MODS_DIR:-mods}"
rc=0

err() { echo "::error::$*"; }

# Parallel arrays and no `declare -A`: this has to run on macOS, which still
# ships bash 3.2. Same constraint as ci/check-mod-workflows.sh.
paths=()  # container path, i.e. everything below the mod's root/
owners=() # mods/<app>/<mod> that ships it

while IFS= read -r f; do
    # mods/<app>/<mod>/root/<container path>
    rest="${f#"${MODS_DIR}"/}"
    app="${rest%%/*}"
    rest="${rest#*/}"
    mod="${rest%%/*}"
    rest="${rest#*/}"
    [[ ${rest} == root/* ]] || continue
    paths+=("${rest#root/}")
    owners+=("${MODS_DIR}/${app}/${mod}")
done < <(find "${MODS_DIR}" -mindepth 4 -path "*/root/*" -type f | sort)

if ((${#paths[@]} == 0)); then
    echo "**** no mod overlay files found under ${MODS_DIR}/ ****"
    exit 0
fi

# Which container paths are shipped by more than one mod?
shared=()
while IFS= read -r p; do
    [[ -n ${p} ]] && shared+=("${p}")
done < <(printf '%s\n' "${paths[@]}" | sort | uniq -d)

if ((${#shared[@]} == 0)); then
    echo "**** no file is shipped by more than one mod; nothing to compare ****"
    exit 0
fi

for p in "${shared[@]}"; do
    # Collect every mod shipping this path, in discovery order. The first is the
    # reference; the rest must match it.
    ref=""
    group=()
    for i in "${!paths[@]}"; do
        [[ ${paths[${i}]} == "${p}" ]] || continue
        group+=("${owners[${i}]}")
    done

    ref="${group[0]}/root/${p}"
    ok=1
    for owner in "${group[@]:1}"; do
        other="${owner}/root/${p}"
        if ! cmp -s "${ref}" "${other}"; then
            err "/${p} differs between ${group[0]} and ${owner}."
            echo "       these are one shared file duplicated per mod; edit every copy together."
            echo "       fix with: cp '${ref}' '${other}'"
            echo "       diff:"
            diff -u "${ref}" "${other}" | sed -n '1,40p' | sed 's/^/         /' || true
            ok=0
            rc=1
        fi
        # Content is not the whole story: s6 ignores a run script that lost its
        # executable bit, so a permission that differs between copies is drift too.
        if { [[ -x ${ref} ]] && [[ ! -x ${other} ]]; } || { [[ ! -x ${ref} ]] && [[ -x ${other} ]]; }; then
            err "/${p} has a different executable bit in ${group[0]} and ${owner}."
            echo "       s6 silently ignores a service script that is not executable; keep the copies identical."
            ok=0
            rc=1
        fi
    done

    if ((ok)); then
        echo "  ok  /${p} -- identical across ${#group[@]} mods:"
        printf '        %s\n' "${group[@]}"
    fi
done

if ((rc == 0)); then
    echo "**** ${#shared[@]} shared file(s), each byte-identical across every mod shipping it ****"
fi
exit $rc
