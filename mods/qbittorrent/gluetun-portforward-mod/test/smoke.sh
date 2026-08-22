#!/bin/bash
# End-to-end smoke test of the mod's state machine against stubbed endpoints.
#
# Unlike test/docker-compose.test.yml this needs no bind mounts: everything is
# baked into throwaway images from tar-piped build contexts, so it runs
# unchanged in CI and on hosts where the docker daemon cannot see the working
# tree. Needs only a working docker.
#
#   bash test/smoke.sh
#
# It drives the real ./run against Caddy stubs for both gluetun and qBittorrent,
# and asserts on the log output and on the requests that actually reached the
# qBittorrent stub. Roughly two minutes.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVC="${REPO}/root/etc/s6-overlay/s6-rc.d/svc-mod-qbittorrent-gluetun-portforward-mod"
WORK="$(mktemp -d)"
NET=qbtsmoke
FAILED=0

cleanup() {
    docker rm -f qbt-gt qbt-app qbt-mod >/dev/null 2>&1
    docker network rm "${NET}" >/dev/null 2>&1
    rm -rf "${WORK}"
}
trap cleanup EXIT

# macOS tars xattrs and AppleDouble files into the build context, and the docker
# daemon then fails with `lsetxattr: xattr "com.apple.provenance"`. GNU tar has
# neither flag, so probe rather than assume.
TAR_FLAGS=()
for _flag in --no-xattrs --no-mac-metadata; do
    if tar "${_flag}" -cf /dev/null -T /dev/null >/dev/null 2>&1; then
        TAR_FLAGS+=("${_flag}")
    fi
done
export COPYFILE_DISABLE=1

ctx() { (cd "$1" && tar "${TAR_FLAGS[@]}" -cf - .); }

build_stub() { # build_stub <image-tag> <caddyfile-path>
    local tag=$1
    local cf=$2
    # Separate `local`s on purpose: within a single `local`, cf is not yet in
    # effect when d is expanded, so every stub would share one directory.
    local d
    d="${WORK}/$(basename "${cf}")"
    mkdir -p "${d}"
    cp "${cf}" "${d}/Caddyfile"
    printf 'FROM caddy:2-alpine\nCOPY Caddyfile /etc/caddy/Caddyfile\n' >"${d}/Dockerfile"
    ctx "${d}" | docker build -q -t "${tag}" - >/dev/null
}

# The mod runner image: bash + curl + jq, i.e. what a linuxserver image provides.
build_runner() {
    local d="${WORK}/runner"
    mkdir -p "${d}"
    cp "${SVC}/run" "${d}/run"
    cp "${SVC}/finish" "${d}/finish"
    # Ship the netns-watchdog helper at the absolute path ./run looks for, so
    # these scenarios exercise the real code path rather than the no-op stubs
    # ./run falls back to when the helper is missing.
    cp "${REPO}/../../../shared/mod-gluetun-portforward/netns-watchdog.sh" "${d}/netns-watchdog.sh"
    # The real shebang is #!/usr/bin/with-contenv bash, which only exists in an
    # LSIO image, so invoke bash explicitly. The script body is plain bash.
    #
    # /dead-netns stands in for a /sys/class/net holding nothing but lo, which is
    # what a container stranded in a destroyed namespace sees. The real one here
    # has eth0, so the watchdog would never fire against it.
    printf 'FROM bash:5\nRUN apk add --no-cache curl jq && mkdir -p /dead-netns && touch /dead-netns/lo\nCOPY run /run.sh\nCOPY finish /finish.sh\nCOPY netns-watchdog.sh /usr/local/lib/mod-gluetun-portforward/netns-watchdog.sh\n' >"${d}/Dockerfile"
    ctx "${d}" | docker build -q -t qbtsmoke/runner - >/dev/null
}

say() { printf '\n\033[1m### %s\033[0m\n' "$*"; }

dump() {
    while IFS= read -r _line; do printf '    | %s\n' "${_line}"; done <<<"$1"
}

expect() {
    if grep -qE "$3" <<<"$1"; then
        printf '  ok   %s\n' "$2"
    else
        printf '  FAIL %s\n         no line matching: %s\n' "$2" "$3"
        FAILED=$((FAILED + 1))
    fi
}
refute() {
    if grep -qE "$3" <<<"$1"; then
        printf '  FAIL %s\n         unexpected line matching: %s\n' "$2" "$3"
        FAILED=$((FAILED + 1))
    else
        printf '  ok   %s (absent)\n' "$2"
    fi
}

run_scenario() { # run_scenario <gluetun-image> <qbt-image> <seconds> [extra env...]
    local gt=$1 qbt=$2 secs=$3
    shift 3
    docker rm -f qbt-gt qbt-app qbt-mod >/dev/null 2>&1
    docker run -d --name qbt-gt --network "${NET}" --network-alias gluetun-stub "${gt}" >/dev/null
    docker run -d --name qbt-app --network "${NET}" --network-alias qbt-stub "${qbt}" >/dev/null
    sleep 3
    local -a envs=(
        -e GLUETUN_PF_CONTROL_URL=http://gluetun-stub:8000
        -e GLUETUN_PF_QBT_URL=http://qbt-stub:8080
        -e GLUETUN_PF_INTERVAL=5
        -e GLUETUN_PF_RETRY_INTERVAL=2
    )
    local e
    for e in "$@"; do envs+=(-e "${e}"); done
    docker run -d --name qbt-mod --network "${NET}" "${envs[@]}" \
        qbtsmoke/runner bash /run.sh >/dev/null
    sleep "${secs}"
    MODLOG="$(docker logs qbt-mod 2>&1)"
    QBTLOG="$(docker logs qbt-app 2>&1)"
}

#------------------------------------------------------------------------------
docker network create "${NET}" >/dev/null 2>&1
build_runner
for cf in "${REPO}"/test/stubs/Caddyfile.*; do
    build_stub "qbtsmoke/$(basename "${cf}" | tr '.' '-' | tr '[:upper:]' '[:lower:]')" "${cf}"
done

#------------------------------------------------------------------------------
say "Scenario 1: happy path -- stale port and both toggles on"
run_scenario qbtsmoke/caddyfile-gluetun-ok qbtsmoke/caddyfile-qbt 14
dump "$MODLOG"
expect "$MODLOG" 'startup banner' '\*\*\*\* starting \*\*\*\*'
expect "$MODLOG" 'detects qBittorrent' 'qBittorrent is answering'
expect "$MODLOG" 'reports the gluetun version' 'gluetun v3\.41\.2'
expect "$MODLOG" 'reports the forwarded port' 'gluetun forwarded port: 54321'
expect "$MODLOG" 'sees the stale listen_port' 'listen_port 6881->54321'
expect "$MODLOG" 'turns random_port off' 'random_port true->false'
expect "$MODLOG" 'turns upnp off' 'upnp true->false'
expect "$MODLOG" 'confirms the write' 'listening port is now 54321'
refute "$MODLOG" 'no auth complaint' '403'
expect "$QBTLOG" 'POSTed to setPreferences' '/api/v2/app/setPreferences'
expect "$QBTLOG" 'read preferences first' '/api/v2/app/preferences'

#------------------------------------------------------------------------------
say "Scenario 2: already in sync -- must write nothing at all"
run_scenario qbtsmoke/caddyfile-gluetun-ok qbtsmoke/caddyfile-qbt-insync 14
dump "$MODLOG"
expect "$MODLOG" 'still reports the port' 'gluetun forwarded port: 54321'
refute "$MODLOG" 'no update attempted' 'updating qBittorrent'
refute "$QBTLOG" 'nothing POSTed' 'setPreferences'

#------------------------------------------------------------------------------
say "Scenario 3: THE qBittorrent-SPECIFIC ONE -- re-apply an unchanged port after an outage"
# qBittorrent does not reliably re-open its listener after the tunnel drops, so
# a port that returns unchanged must still be written once. Start with gluetun
# reporting nothing, then give it a port that already matches qBittorrent's
# settings: a mod that only wrote on change would do nothing here.
docker rm -f qbt-gt qbt-app qbt-mod >/dev/null 2>&1
docker run -d --name qbt-gt --network "${NET}" --network-alias gluetun-stub qbtsmoke/caddyfile-gluetun-zero >/dev/null
docker run -d --name qbt-app --network "${NET}" --network-alias qbt-stub qbtsmoke/caddyfile-qbt-insync >/dev/null
sleep 3
docker run -d --name qbt-mod --network "${NET}" \
    -e GLUETUN_PF_CONTROL_URL=http://gluetun-stub:8000 \
    -e GLUETUN_PF_QBT_URL=http://qbt-stub:8080 \
    -e GLUETUN_PF_INTERVAL=5 -e GLUETUN_PF_RETRY_INTERVAL=2 \
    qbtsmoke/runner bash /run.sh >/dev/null
sleep 8
MODLOG="$(docker logs qbt-mod 2>&1)"
expect "$MODLOG" 'sees no forwarded port' 'no forwarded port yet'
refute "$MODLOG" 'leaves qBittorrent alone meanwhile' 'listening port is now'
# Now the port comes back, matching what qBittorrent already has.
docker rm -f qbt-gt >/dev/null 2>&1
docker run -d --name qbt-gt --network "${NET}" --network-alias gluetun-stub qbtsmoke/caddyfile-gluetun-ok >/dev/null
sleep 12
MODLOG="$(docker logs qbt-mod 2>&1)"
QBTLOG="$(docker logs qbt-app 2>&1)"
dump "$MODLOG"
expect "$MODLOG" 're-applies the unchanged port' 're-applying 54321 after a port outage'
expect "$MODLOG" 'and confirms the write' 'listening port is now 54321'
expect "$QBTLOG" 'the write really reached qBittorrent' 'setPreferences'

#------------------------------------------------------------------------------
say "Scenario 4: qBittorrent refuses everything (403) -- no credentials, no bypass"
run_scenario qbtsmoke/caddyfile-gluetun-ok qbtsmoke/caddyfile-qbt-403 12
dump "$MODLOG"
expect "$MODLOG" 'names the 403' 'refused the request \(HTTP 403 Forbidden\)'
expect "$MODLOG" 'offers the bypass option' 'Bypass authentication'
expect "$MODLOG" 'offers the password option' 'GLUETUN_PF_QBT_USERNAME'
expect "$MODLOG" 'warns the temporary password is useless' 'regenerated every'
n=$(grep -c 'refused the request' <<<"$MODLOG")
if ((n == 1)); then
    printf '  ok   advice printed exactly once, not every poll\n'
else
    printf '  FAIL advice printed %d times\n' "$n"
    FAILED=$((FAILED + 1))
fi

#------------------------------------------------------------------------------
say "Scenario 5: credentials -- login, carry the SID cookie, then write"
run_scenario qbtsmoke/caddyfile-gluetun-ok qbtsmoke/caddyfile-qbt-auth 14 \
    GLUETUN_PF_QBT_USERNAME=admin GLUETUN_PF_QBT_PASSWORD=secret
dump "$MODLOG"
expect "$MODLOG" 'authenticates' "authenticated to qBittorrent as 'admin'"
expect "$MODLOG" 'then writes the port' 'listening port is now 54321'
expect "$QBTLOG" 'hit the login endpoint' '/api/v2/auth/login'
refute "$MODLOG" 'never falls back to the 403 advice' 'refused the request'

#------------------------------------------------------------------------------
say "Scenario 6: wrong credentials -- qBittorrent answers 200 with 'Fails.'"
run_scenario qbtsmoke/caddyfile-gluetun-ok qbtsmoke/caddyfile-qbt-authfail 12 \
    GLUETUN_PF_QBT_USERNAME=admin GLUETUN_PF_QBT_PASSWORD=wrong
dump "$MODLOG"
expect "$MODLOG" 'detects the rejection despite the 200' 'rejected the credentials'
expect "$MODLOG" 'explains the temporary password' 'temporary admin password'
refute "$MODLOG" 'does not claim success' 'listening port is now'

#------------------------------------------------------------------------------
say "Scenario 7: gluetun legacy 401 route (v3.39.1-v3.40.4) must not read as an auth failure"
run_scenario qbtsmoke/caddyfile-gluetun-legacy qbtsmoke/caddyfile-qbt 12
expect "$MODLOG" 'falls back to the legacy route' 'using route /v1/openvpn/portforwarded'
expect "$MODLOG" 'still writes the port' 'listening port is now 54321'
refute "$MODLOG" 'no gluetun auth help' 'Unauthorized on every known'

#------------------------------------------------------------------------------
say "Scenario 8: multi-port provider"
run_scenario qbtsmoke/caddyfile-gluetun-multi qbtsmoke/caddyfile-qbt 12
expect "$MODLOG" 'picks the lowest and shows the set' 'forwarded port: 1024 \(all: 1024 2048 4096\)'
expect "$MODLOG" 'writes the lowest' 'listen_port 6881->1024'

say "Scenario 8b: same, with GLUETUN_PF_PORT_INDEX=2"
run_scenario qbtsmoke/caddyfile-gluetun-multi qbtsmoke/caddyfile-qbt 12 GLUETUN_PF_PORT_INDEX=2
expect "$MODLOG" 'honours the index' 'forwarded port: 4096'
expect "$MODLOG" 'writes the selected port' 'listen_port 6881->4096'

#------------------------------------------------------------------------------
say "Scenario 9: GLUETUN_PF_MANAGE_PORT_TOGGLES=false leaves random_port and upnp alone"
run_scenario qbtsmoke/caddyfile-gluetun-ok qbtsmoke/caddyfile-qbt 12 GLUETUN_PF_MANAGE_PORT_TOGGLES=false
dump "$MODLOG"
expect "$MODLOG" 'says the toggles are left alone' 'random_port / upnp     : left alone'
expect "$MODLOG" 'still sets the port' 'listen_port 6881->54321'
refute "$MODLOG" 'does not mention random_port as a change' 'random_port true->false'

#------------------------------------------------------------------------------
say "Scenario 10: GLUETUN_PF_ENABLED=false makes it inert"
run_scenario qbtsmoke/caddyfile-gluetun-ok qbtsmoke/caddyfile-qbt 6 GLUETUN_PF_ENABLED=false
expect "$MODLOG" 'says it is inert' 'will stay inert'
refute "$MODLOG" 'does not start the loop' 'gluetun control server :'
code=$(
    docker run --rm -e GLUETUN_PF_ENABLED=false qbtsmoke/runner bash /finish.sh 0 0 >/dev/null 2>&1
    echo $?
)
if [[ ${code} == 125 ]]; then
    printf '  ok   finish returns 125 when disabled (s6 keeps it down)\n'
else
    printf '  FAIL finish returned %s, expected 125\n' "${code}"
    FAILED=$((FAILED + 1))
fi

#------------------------------------------------------------------------------
say "Scenario 11: the netns watchdog is off unless it is asked for"
# The whole safety promise of the feature: someone already pulling :latest must
# see byte-identical behaviour until they set the flag.
run_scenario qbtsmoke/caddyfile-gluetun-ok qbtsmoke/caddyfile-qbt 10 \
    GLUETUN_PF_NETNS_SYSFS=/dead-netns
refute "$MODLOG" 'says nothing about a watchdog' 'netns watchdog'
refute "$MODLOG" 'does not report a strike' 'stranded in a dead network namespace'
expect "$MODLOG" 'and still does its actual job' 'listening port is now 54321'
if [[ $(docker inspect -f '{{.State.Running}}' qbt-mod) == true ]]; then
    printf '  ok   still running -- a dead namespace alone halts nothing\n'
else
    printf '  FAIL the mod exited with the watchdog unset\n'
    FAILED=$((FAILED + 1))
fi

#------------------------------------------------------------------------------
say "Scenario 11b: dry run reaches the decision and refuses to act on it"
# The halt itself replaces PID 1 of a real s6 container and cannot be reached
# from here, which is exactly why the dry-run flag exists.
run_scenario qbtsmoke/caddyfile-gluetun-ok qbtsmoke/caddyfile-qbt 14 \
    GLUETUN_PF_NETNS_SYSFS=/dead-netns \
    GLUETUN_PF_NETNS_WATCHDOG=true GLUETUN_PF_NETNS_WATCHDOG_DRY_RUN=true \
    GLUETUN_PF_NETNS_WATCHDOG_GRACE=0 GLUETUN_PF_NETNS_WATCHDOG_STRIKES=2
dump "$MODLOG"
expect "$MODLOG" 'announces itself as a dry run' 'netns watchdog *: DRY RUN'
expect "$MODLOG" 'counts a strike' 'stranded in a dead network namespace \(strike 1/2\)'
expect "$MODLOG" 'reaches the threshold' 'strike 2/2'
expect "$MODLOG" 'says what it would have done' 'DRY RUN: would halt the container now with exit 70'
if [[ $(docker inspect -f '{{.State.Running}}' qbt-mod) == true ]]; then
    printf '  ok   still running -- dry run halts nothing\n'
else
    printf '  FAIL dry run halted the container\n'
    FAILED=$((FAILED + 1))
fi

#------------------------------------------------------------------------------
say "Scenario 12: SIGTERM shuts down promptly instead of waiting out the poll"
docker rm -f qbt-mod >/dev/null 2>&1
docker run -d --name qbt-mod --network "${NET}" \
    -e GLUETUN_PF_CONTROL_URL=http://gluetun-stub:8000 \
    -e GLUETUN_PF_QBT_URL=http://qbt-stub:8080 \
    -e GLUETUN_PF_INTERVAL=300 -e GLUETUN_PF_RETRY_INTERVAL=2 \
    qbtsmoke/runner bash /run.sh >/dev/null
sleep 6
start=$(date +%s)
docker stop -t 30 qbt-mod >/dev/null
elapsed=$(($(date +%s) - start))
MODLOG="$(docker logs qbt-mod 2>&1)"
expect "$MODLOG" 'logs the shutdown' 'shutting down'
if ((elapsed <= 5)); then
    printf '  ok   stopped in %ds despite a 300s poll interval\n' "${elapsed}"
else
    printf '  FAIL took %ds to stop; the sleep is not interruptible\n' "${elapsed}"
    FAILED=$((FAILED + 1))
fi

#------------------------------------------------------------------------------
printf '\n'
if ((FAILED)); then
    printf '\033[1;31m%d smoke assertion(s) FAILED\033[0m\n' "${FAILED}"
    exit 1
fi
printf '\033[1;32mAll smoke assertions passed\033[0m\n'
