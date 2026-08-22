#!/usr/bin/env bash
# Scaffold a new mod from template/ into mods/<app>/<modname>/, and write the
# per-mod CI workflow that goes with it.
#
#   ci/new-mod.sh <app> <modname>
#   ci/new-mod.sh plex remove-codecs   -> mods/plex/remove-codecs/
#
# mods/ is grouped by the application being modded. The GHCR package name is
# <app>-<modname>, composed from the two directory levels.
#
# MODS_DIR and WF_DIR can be pointed at scratch directories to scaffold without
# touching the repo; ci/ uses that to check the template still produces a valid
# mod without leaving one behind.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

MODS_DIR="${MODS_DIR:-mods}"
WF_DIR="${WF_DIR:-.github/workflows}"

usage() {
    echo "usage: ci/new-mod.sh <app> <modname>" >&2
    echo "  e.g. ci/new-mod.sh plex remove-codecs   -> mods/plex/remove-codecs/" >&2
    exit 2
}

[[ $# -eq 2 ]] || usage
APP="$1"
NAME="$2"

# Both halves end up in s6 service directory names, a workflow filename and a
# GHCR package name, so keep them to the lowercase-and-dashes charset all three
# tolerate. This also keeps `@` out, which the substitution below relies on.
for v in "${APP}" "${NAME}"; do
    [[ ${v} =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] ||
        { echo "invalid name '${v}': use lowercase letters, digits and single dashes" >&2; exit 1; }
done

[[ -d template ]] || { echo "template/ is missing" >&2; exit 1; }

# The id is what the workflow file and the GHCR package are named after; the
# directory is the two-level path.
MOD="${APP}-${NAME}"
DIR="${MODS_DIR}/${APP}/${NAME}"
WF="${WF_DIR}/mod-${MOD}.yml"

[[ -e ${DIR} ]] && { echo "${DIR} already exists" >&2; exit 1; }
[[ -e ${WF} ]] && { echo "${WF} already exists" >&2; exit 1; }

# Different splits can compose to the same id: plex/foo-bar and plex-foo/bar are
# both "plex-foo-bar", which is one GHCR package and one workflow file. The
# existing-file checks above catch it only by accident, and not at all if the
# clash is with a directory that was created by hand.
if [[ -d ${MODS_DIR} ]]; then
    while IFS= read -r other; do
        [[ -z ${other} ]] && continue
        other_mod="$(basename "${other}")"
        other_app="$(basename "$(dirname "${other}")")"
        if [[ "${other_app}-${other_mod}" == "${MOD}" ]]; then
            echo "id '${MOD}' is already taken by ${MODS_DIR}/${other_app}/${other_mod}" >&2
            echo "  both would publish to the same GHCR package and share one workflow file" >&2
            exit 1
        fi
    done < <(find "${MODS_DIR}" -mindepth 2 -maxdepth 2 -type d 2>/dev/null)
fi

mkdir -p "${MODS_DIR}/${APP}" "${WF_DIR}"
cp -R template "${DIR}"

# Rename the placeholder service directories, deepest first so the parents are
# still where find left them.
while IFS= read -r p; do
    mv "${p}" "$(dirname "${p}")/$(basename "${p}" | sed "s/imagename-modname/${MOD}/")"
done < <(find "${DIR}" -depth -name '*imagename-modname*')

# Then the placeholders inside the files, in two phases.
#
# The obvious single pass is wrong: sed applies -e expressions in sequence to
# the same line, so a later rule re-matches text an earlier one just wrote.
# `ci/new-mod.sh plex fix-imagename` would turn `imagename-modname` into
# `plex-fix-imagename` and then into `plex-fix-plex`, leaving the `up` file
# pointing at a service directory that does not exist.
#
# So: map every placeholder to a sentinel first, then map sentinels to values.
# `@@` cannot occur in the template, and the validator above forbids it in the
# values, so neither phase can feed the other.
while IFS= read -r f; do
    sed -i.bak \
        -e 's/imagename-modname/@@ID@@/g' \
        -e 's/imagename/@@APP@@/g' \
        -e 's/modname/@@NAME@@/g' \
        -e "s/@@ID@@/${MOD}/g" \
        -e "s/@@APP@@/${APP}/g" \
        -e "s/@@NAME@@/${NAME}/g" \
        -e "s/^# Modname /# ${NAME} /" \
        "${f}"
    rm -f "${f}.bak"
done < <(find "${DIR}" -type f)

# Spread the nightly crons out. GitHub queues everything scheduled for the same
# instant together, and on a busy hour it drops runs, so derive a stable
# per-mod slot from the name rather than putting every mod on the same minute.
_cksum="$(printf '%s' "${MOD}" | cksum | awk '{print $1}')"
CRON_MIN=$((_cksum % 60))
CRON_HR=$((_cksum / 60 % 4 + 2)) # 02:00-05:59 UTC

# The per-mod workflow. The paths filter is what makes this mod's CI run only
# when this mod changes, and the schedule is its nightly build from develop;
# ci/check-mod-workflows.sh enforces that both stay in place.
cat >"${WF}" <<EOF
name: ${MOD}

# One workflow per mod. The \`paths:\` filter is the whole point: GitHub skips
# this entirely unless this mod's own directory changed, so touching one mod
# never runs another's tests.
#
# The \`schedule:\` produces this mod's nightly build from \`develop\`. Note that
# GitHub only ever fires scheduled runs from the DEFAULT branch's copy of a
# workflow file, which is why the nightly checks \`develop\` out explicitly rather
# than running on it -- and why a new mod added on develop gets no nightlies
# until its workflow reaches master.
#
# The cron minute is derived from the mod name so that many mods do not all
# queue at the same instant.
#
# Generated by ci/new-mod.sh. If you rename or add a mod, keep this file in step
# -- the repo workflow fails when a mod has no caller, or a caller has no mod.

on:
  push:
    # Branches only: a tag push would otherwise trigger every mod whose paths
    # happen to match, and build a ref that is not a branch.
    branches: ['**']
    paths:
      - 'mods/${APP}/${NAME}/**'
      - '.github/workflows/mod-${MOD}.yml'
      - '.github/workflows/_mod-ci.yml'
  pull_request:
    paths:
      - 'mods/${APP}/${NAME}/**'
      - '.github/workflows/mod-${MOD}.yml'
      - '.github/workflows/_mod-ci.yml'
  schedule:
    - cron: '${CRON_MIN} ${CRON_HR} * * *'
  workflow_dispatch:
    inputs:
      tag:
        description: 'Publish under this exact tag (e.g. rc1). Blank = the normal channel tags for the branch you run this from.'
        required: false
        type: string

# A publish moves a shared tag, so two runs for the same ref must not overlap:
# push twice to develop a minute apart and both runs push :nightly, with the
# older one free to land last. Serialised rather than cancelled -- killing a run
# mid-push is how a manifest ends up half-written, and the queued run is the
# newer commit anyway.
concurrency:
  group: \${{ github.workflow }}-\${{ github.ref }}
  cancel-in-progress: false

permissions:
  contents: read
  packages: write

jobs:
  ci:
    uses: ./.github/workflows/_mod-ci.yml
    with:
      app: ${APP}
      mod: ${NAME}
      # Manual runs only: everything else leaves this blank and gets the
      # channel tags. A tag here publishes that tag alone.
      tag: \${{ github.event_name == 'workflow_dispatch' && inputs.tag || '' }}
      # The nightly always builds develop; everything else builds whatever ref
      # triggered it.
      ref: \${{ github.event_name == 'schedule' && 'refs/heads/develop' || github.ref }}
      # develop publishes :nightly, master publishes :latest.
      channel: \${{ (github.event_name == 'schedule' || github.ref == 'refs/heads/develop') && 'nightly' || 'release' }}
      # Publish from either channel branch: a push to master moves :latest, a
      # push to develop moves :nightly, so develop is genuinely "the current
      # develop" rather than "develop as of last night". The nightly schedule
      # still runs, and still republishes only when the mod's content changed --
      # the pin is content-addressed, so an unchanged tree is a no-op.
      #
      # A manual run publishes too: from master or develop for the channel tags,
      # or from any branch at all when a custom tag is given. Pushes to feature
      # branches and all pull requests test only.
      publish: >-
        \${{ github.event_name == 'schedule'
            || (github.event_name == 'push'
                && (github.ref == 'refs/heads/master'
                    || github.ref == 'refs/heads/develop'))
            || (github.event_name == 'workflow_dispatch'
                && (inputs.tag != ''
                    || github.ref == 'refs/heads/master'
                    || github.ref == 'refs/heads/develop')) }}
EOF

echo "created ${DIR}"
echo "created ${WF}"
echo
echo "next:"
echo "  1. edit ${DIR}/README.md"
echo "  2. delete whichever of init-mod-* (oneshot) / svc-mod-* (longrun) you do"
echo "     not need, together with its entry in root/etc/s6-overlay/s6-rc.d/user/contents.d/"
echo "     and in init-mods-end/dependencies.d/"
echo "  3. add the mod to the table in README.md"
echo "  4. push; ${WF} tests it, and publishes"
echo "     ghcr.io/<owner>/${MOD}:latest from master"
