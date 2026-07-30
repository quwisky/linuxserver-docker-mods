#!/usr/bin/env bash
# Checks that mods/ has the shape everything else assumes: exactly two levels,
# app then mod, with a Dockerfile at the bottom.
#
#   ci/check-mod-layout.sh
#
# This lives in a script rather than inline in a workflow for two reasons: the
# repo's shellcheck step only lints ci/ and template/, so inline workflow bash
# is the one kind of shell nobody checks; and the discovery rule belongs in one
# place, next to ci/check-mod-workflows.sh which globs the same shape.
#
# MODS_DIR can point elsewhere for testing.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

MODS_DIR="${MODS_DIR:-mods}"
rc=0

err() { echo "::error::$*"; }

# Match dotfiles too. A stray mods/plex/.DS_Store is exactly the kind of thing
# this check exists to name, and a bare * would skip it silently.
shopt -s dotglob nullglob

if [[ ! -d ${MODS_DIR} ]]; then
    err "${MODS_DIR}/ does not exist. There is nothing to build."
    exit 1
fi

apps=("${MODS_DIR}"/*)
if ((${#apps[@]} == 0)); then
    # Reporting green for a repo with no mods left would make a catastrophic
    # deletion indistinguishable from a healthy tree.
    err "${MODS_DIR}/ is empty. There is nothing to build."
    exit 1
fi

found=0
for app in "${apps[@]}"; do
    name="$(basename "${app}")"
    case "${name}" in
        .git* | .DS_Store)
            err "${app} does not belong in ${MODS_DIR}/"
            rc=1
            continue
            ;;
    esac

    if [[ ! -d ${app} ]]; then
        err "${app} is not a directory; ${MODS_DIR}/ holds one directory per application"
        rc=1
        continue
    fi

    if [[ -f "${app}/Dockerfile" ]]; then
        err "${app} looks like a mod, but mods live at ${MODS_DIR}/<app>/<mod>. Move it down a level."
        rc=1
        continue
    fi

    entries=("${app}"/*)
    if ((${#entries[@]} == 0)); then
        err "${app} contains no mods"
        rc=1
        continue
    fi

    for mod in "${entries[@]}"; do
        if [[ ! -d ${mod} ]]; then
            err "${mod} is not a directory; ${MODS_DIR}/<app>/ holds one directory per mod"
            rc=1
        elif [[ ! -f "${mod}/Dockerfile" ]]; then
            err "${mod} has no Dockerfile, so it is not a buildable mod"
            rc=1
        else
            found=$((found + 1))
        fi
    done
done

if ((rc == 0 && found == 0)); then
    err "no buildable mods found under ${MODS_DIR}/"
    rc=1
fi

((rc == 0)) && echo "**** ${MODS_DIR}/ layout is valid: ${found} mod(s) ****"
exit $rc
