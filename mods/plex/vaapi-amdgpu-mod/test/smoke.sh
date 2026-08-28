#!/usr/bin/env bash
# Runtime integration test against the current linuxserver/plex image.
#
# This deliberately starts with an empty /config and PUID/PGID 1000. The mod's
# init service runs as root because it wraps files under /usr/lib; the regression
# this catches is accidentally creating Plex's data directory as root too, which
# prevents the normal application user from starting Plex.
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "${MOD_DIR}/../../.." && pwd)"
WORK="$(mktemp -d)"
NAME=vaapismoke-plex
MOD_IMAGE=vaapismoke/mod
PLEX_IMAGE=vaapismoke/plex

cleanup() {
    docker rm -fv "${NAME}" >/dev/null 2>&1 || true
    rm -rf "${WORK}"
}
trap cleanup EXIT

fail() {
    echo "FAIL $*" >&2
    docker logs "${NAME}" 2>&1 | tail -80 >&2 || true
    exit 1
}

if ! docker build --platform linux/amd64 \
    -f "${MOD_DIR}/Dockerfile" -t "${MOD_IMAGE}" "${REPO}" \
    >"${WORK}/mod-build.log" 2>&1; then
    cat "${WORK}/mod-build.log" >&2
    fail "mod image did not build"
fi

cat >"${WORK}/Dockerfile" <<EOF
FROM ${MOD_IMAGE} AS mod
FROM lscr.io/linuxserver/plex:latest
COPY --from=mod / /
EOF
if ! docker build -q -t "${PLEX_IMAGE}" "${WORK}" >"${WORK}/plex-build.log" 2>&1; then
    cat "${WORK}/plex-build.log" >&2
    fail "Plex integration image did not build"
fi

# The scratch mod image contains its own musl loader, so verify the complete
# driver dependency closure without needing a GPU.
deps="$(docker run --rm -e LD_LIBRARY_PATH=/vaapi-amdgpu/lib \
    --entrypoint /vaapi-amdgpu/lib/ld-musl-x86_64.so.1 "${MOD_IMAGE}" \
    --list /vaapi-amdgpu/lib/dri/radeonsi_drv_video.so 2>&1)" || {
        echo "${deps}" >&2
        fail "radeonsi dependency closure does not load"
    }
[[ ${deps} != *"Error loading"* ]] || fail "radeonsi has a missing dependency"

docker run -d --name "${NAME}" --tmpfs /config \
    -e PUID=1000 -e PGID=1000 -e TZ=Etc/UTC -e VERSION=docker \
    "${PLEX_IMAGE}" >/dev/null

ready=0
for ((attempt = 0; attempt < 45; attempt++)); do
    if docker exec "${NAME}" curl -fsS http://127.0.0.1:32400/identity >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done
((ready)) || fail "Plex did not start with a fresh config"

PLEX_DATA_DIR="/config/Library/Application Support/Plex Media Server"
owner="$(docker exec "${NAME}" stat -c '%u:%g' "${PLEX_DATA_DIR}")"
[[ ${owner} == 1000:1000 ]] || fail "fresh Plex data directory is owned by ${owner}, expected 1000:1000"

docker exec "${NAME}" test -x "/usr/lib/plexmediaserver/Plex Transcoder.orig"
docker exec "${NAME}" test -x "/usr/lib/plexmediaserver/Plex Media Server.orig"
docker exec "${NAME}" test -L "${PLEX_DATA_DIR}/Cache/va-dri-linux-x86_64/radeonsi_drv_video.so"

# Reproduce the ownership left by the old release, including a missing driver
# cache below root-owned ancestors. The next invocation must repair it, preserve
# the original binaries and leave the live server healthy.
docker exec "${NAME}" sh -c \
    'chown 0:0 "$1" "$1/Cache" && rm -rf "$1/Cache/va-dri-linux-x86_64"' \
    sh "${PLEX_DATA_DIR}"
second="$(docker exec "${NAME}" /usr/bin/with-contenv bash \
    /etc/s6-overlay/s6-rc.d/init-mod-vaapi-amdgpu/run)"
[[ ${second} == *"Transcoder wrapper already exists"* ]]
[[ ${second} == *"Plex Media Server wrapper already exists"* ]]
for directory in "${PLEX_DATA_DIR}" "${PLEX_DATA_DIR}/Cache" "${PLEX_DATA_DIR}/Cache/va-dri-linux-x86_64"; do
    owner="$(docker exec "${NAME}" stat -c '%u:%g' "${directory}")"
    [[ ${owner} == 1000:1000 ]] || fail "repaired directory ${directory} is owned by ${owner}"
done
docker exec "${NAME}" curl -fsS http://127.0.0.1:32400/identity >/dev/null

echo "All VAAPI smoke assertions passed"
