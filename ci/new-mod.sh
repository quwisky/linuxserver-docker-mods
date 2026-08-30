#!/usr/bin/env bash
# Scaffold an independently versioned mod under mods/<app>/<modname>/.
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

MODS_DIR="${MODS_DIR:-mods}"

usage() {
    printf 'usage: ci/new-mod.sh <app> <modname>\n' >&2
    printf '  e.g. ci/new-mod.sh plex remove-codecs -> mods/plex/remove-codecs/\n' >&2
    exit 2
}

[[ $# -eq 2 ]] || usage
APP="$1"
NAME="$2"
for value in "${APP}" "${NAME}"; do
    [[ ${value} =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || {
        printf "invalid name '%s': use lowercase letters, digits and single dashes\n" "${value}" >&2
        exit 1
    }
done

[[ -d template ]] || { printf 'template/ is missing\n' >&2; exit 1; }

ID="${APP}-${NAME}"
DIR="${MODS_DIR}/${APP}/${NAME}"
[[ ! -e ${DIR} ]] || { printf '%s already exists\n' "${DIR}" >&2; exit 1; }

if [[ -d ${MODS_DIR} ]]; then
    while IFS= read -r other; do
        [[ -n ${other} ]] || continue
        other_mod="$(basename "${other}")"
        other_app="$(basename "$(dirname "${other}")")"
        if [[ ${other_app}-${other_mod} == "${ID}" ]]; then
            printf "id '%s' is already taken by %s/%s/%s\n" \
                "${ID}" "${MODS_DIR}" "${other_app}" "${other_mod}" >&2
            exit 1
        fi
    done < <(find "${MODS_DIR}" -mindepth 2 -maxdepth 2 -type d 2>/dev/null)
fi

mkdir -p "${MODS_DIR}/${APP}"
cp -Rp template "${DIR}"

while IFS= read -r path; do
    mv "${path}" "$(dirname "${path}")/$(basename "${path}" | sed "s/imagename-modname/${ID}/")"
done < <(find "${DIR}" -depth -name '*imagename-modname*')

while IFS= read -r file; do
    temporary="$(mktemp "${TMPDIR:-/tmp}/new-mod.XXXXXX")"
    trap 'rm -f "${temporary:-}"' EXIT
    sed \
        -e 's/imagename-modname/@@ID@@/g' \
        -e 's/imagename/@@APP@@/g' \
        -e 's/modname/@@NAME@@/g' \
        -e "s/@@ID@@/${ID}/g" \
        -e "s/@@APP@@/${APP}/g" \
        -e "s/@@NAME@@/${NAME}/g" \
        -e "s/^# Modname /# ${NAME} /" \
        "${file}" >"${temporary}"
    command cat "${temporary}" >"${file}"
    rm -f "${temporary}"
    trap - EXIT
done < <(find "${DIR}" -type f)

printf 'created %s\n\n' "${DIR}"
printf '%s\n' 'next:'
printf '  1. edit %s/README.md\n' "${DIR}"
printf '%s\n' '  2. remove the unused oneshot or longrun service skeleton'
printf '%s\n' '  3. add the mod to README.md and add a .changes/*.json fragment'
printf '%s\n' '  4. open a pull request; aggregate CI discovers and tests the mod'
