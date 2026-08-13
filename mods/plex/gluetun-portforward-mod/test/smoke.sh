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
# It drives the real ./run against Caddy stubs for both gluetun and Plex, and
# asserts on the log output and on the requests that actually reached the Plex
# stub. Roughly two minutes.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVC="${REPO}/root/etc/s6-overlay/s6-rc.d/svc-mod-plex-gluetun-portforward-mod"
WORK="$(mktemp -d)"
NET=pfsmoke
FAILED=0

cleanup() {
    docker rm -f pfs-gt pfs-plex pfs-mod >/dev/null 2>&1
    docker network rm "${NET}" >/dev/null 2>&1
    rm -rf "${WORK}"
}
trap cleanup EXIT

# macOS tars xattrs and AppleDouble files into the build context, and the docker
# daemon then fails with `lsetxattr: xattr "com.apple.provenance"`. GNU tar has
# neither flag, so probe rather than assume. `-cf /dev/null -T /dev/null` builds
# an empty archive on both implementations.
TAR_FLAGS=()
for _flag in --no-xattrs --no-mac-metadata; do
    if tar "${_flag}" -cf /dev/null -T /dev/null >/dev/null 2>&1; then
        TAR_FLAGS+=("${_flag}")
    fi
done
export COPYFILE_DISABLE=1

ctx() { # ctx <dir> -> a tar stream of it on stdout, safe for `docker build -`
    (cd "$1" && tar "${TAR_FLAGS[@]}" -cf - .)
}

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

# The mod runner image: bash + curl + jq, i.e. what linuxserver/plex already has.
build_runner() {
    local d="${WORK}/runner"
    mkdir -p "${d}"
    cp "${SVC}/run" "${d}/run"
    cp "${SVC}/finish" "${d}/finish"
    # Ship the netns-watchdog helper at the absolute path ./run looks for, so
    # these scenarios exercise the real code path rather than the no-op stubs
    # ./run falls back to when the helper is missing.
    cp "${REPO}/root/usr/local/lib/mod-gluetun-portforward/netns-watchdog.sh" "${d}/netns-watchdog.sh"
    # The real shebang is #!/usr/bin/with-contenv bash, which only exists in an
    # LSIO image, so invoke bash explicitly. The script body is plain bash, and
    # bash+curl+jq is exactly what linuxserver/plex already provides.
    #
    # /dead-netns stands in for a /sys/class/net holding nothing but lo, which is
    # what a container stranded in a destroyed namespace sees. The real one here
    # has eth0, so the watchdog would never fire against it.
    printf 'FROM bash:5\nRUN apk add --no-cache curl jq && mkdir -p /dead-netns && touch /dead-netns/lo\nCOPY run /run.sh\nCOPY finish /finish.sh\nCOPY netns-watchdog.sh /usr/local/lib/mod-gluetun-portforward/netns-watchdog.sh\n' >"${d}/Dockerfile"
    ctx "${d}" | docker build -q -t pfsmoke/runner - >/dev/null
}

say() { printf '\n\033[1m### %s\033[0m\n' "$*"; }

dump() { # indent a captured log so it is obvious which output is the mod's
    while IFS= read -r _line; do printf '    | %s\n' "${_line}"; done <<<"$1"
}

# expect <log> <name> <pattern>
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

run_scenario() { # run_scenario <gluetun-image> <plex-image> <seconds> [extra env...]
    local gt=$1 px=$2 secs=$3
    shift 3
    docker rm -f pfs-gt pfs-plex pfs-mod >/dev/null 2>&1
    docker run -d --name pfs-gt --network "${NET}" --network-alias gluetun-stub "${gt}" >/dev/null
    docker run -d --name pfs-plex --network "${NET}" --network-alias plex-stub "${px}" >/dev/null
    sleep 3
    local -a envs=(
        -e GLUETUN_PF_CONTROL_URL=http://gluetun-stub:8000
        -e GLUETUN_PF_PLEX_URL=http://plex-stub:32400
        -e GLUETUN_PF_PLEX_TOKEN=stub-token
        -e GLUETUN_PF_INTERVAL=5
        -e GLUETUN_PF_RETRY_INTERVAL=2
    )
    local e
    for e in "$@"; do envs+=(-e "${e}"); done
    docker run -d --name pfs-mod --network "${NET}" "${envs[@]}" \
        pfsmoke/runner bash /run.sh >/dev/null
    sleep "${secs}"
    MODLOG="$(docker logs pfs-mod 2>&1)"
    PLEXLOG="$(docker logs pfs-plex 2>&1)"
}

#------------------------------------------------------------------------------
docker network create "${NET}" >/dev/null 2>&1
build_runner
for cf in "${REPO}"/test/stubs/Caddyfile.*; do
    build_stub "pfsmoke/$(basename "${cf}" | tr '.' '-' | tr '[:upper:]' '[:lower:]')" "${cf}"
done

#------------------------------------------------------------------------------
say "Scenario 1: happy path (gluetun v3.41.2 shape)"
run_scenario pfsmoke/caddyfile-gluetun-ok pfsmoke/caddyfile-plex 40
dump "$MODLOG"
expect "$MODLOG" 'startup banner' '\*\*\*\* starting \*\*\*\*'
expect "$MODLOG" 'warns about the gluetun redirect' 'VPN_PORT_FORWARDING_LISTENING_PORT=32400'
expect "$MODLOG" 'detects Plex' 'Plex is answering'
expect "$MODLOG" 'uses the token override' 'using Plex token from GLUETUN_PF_PLEX_TOKEN'
expect "$MODLOG" 'logs the gluetun version' 'gluetun v3\.41\.2, using route /v1/portforward'
expect "$MODLOG" 'reports the forwarded port' 'gluetun forwarded port: 54321'
expect "$MODLOG" 'sees both settings are wrong' 'ManualPortMappingPort 32400->54321'
expect "$MODLOG" 'flips the mapping mode too' 'ManualPortMappingMode 0->1'
expect "$MODLOG" 'and the publish switch' 'PublishServerOnPlexOnlineKey 0->1'
expect "$MODLOG" 'confirms the write' 'Plex public port is now 54321'
refute "$MODLOG" 'no auth help' '401'
refute "$MODLOG" 'no token leak' 'stub-token'
expect "$PLEXLOG" 'PUT carried all three settings, correctly cased' \
    'PublishServerOnPlexOnlineKey=1&ManualPortMappingMode=1&ManualPortMappingPort=54321'
# The stub never changes its reported values, so the "not sticking" guard must
# eventually trip rather than writing once per poll forever.
expect "$MODLOG" 'trips the not-sticking guard instead of writing forever' 'not sticking'
n_put=$(grep -c '"method":"PUT"' <<<"$PLEXLOG")
if ((n_put <= 4)); then
    printf '  ok   write rate is bounded (%d PUTs in 40s)\n' "$n_put"
else
    printf '  FAIL write rate unbounded: %d PUTs in 40s\n' "$n_put"
    FAILED=$((FAILED + 1))
fi

#------------------------------------------------------------------------------
say "Scenario 2: THE REGRESSION TEST - gluetun v3.39.1-v3.40.4 answers 401 on /v1/portforward"
run_scenario pfsmoke/caddyfile-gluetun-legacy pfsmoke/caddyfile-plex 10
dump "$MODLOG"
expect "$MODLOG" 'falls back to the legacy route' 'using route /v1/openvpn/portforwarded'
expect "$MODLOG" 'still gets the port' 'gluetun forwarded port: 54321'
expect "$MODLOG" 'still updates Plex' 'Plex public port is now 54321'
refute "$MODLOG" 'does NOT misdiagnose it as an auth failure' 'Unauthorized on every known'

#------------------------------------------------------------------------------
say "Scenario 3: genuine auth failure (every route 401s)"
run_scenario pfsmoke/caddyfile-gluetun-401 pfsmoke/caddyfile-plex 10
dump "$MODLOG"
expect "$MODLOG" 'diagnoses auth' '401 Unauthorized on every known port-forward route'
expect "$MODLOG" 'prints a pasteable role' 'routes = \['
n_auth=$(grep -c 'Unauthorized on every known' <<<"$MODLOG")
if ((n_auth == 1)); then
    printf '  ok   auth help printed exactly once, not every poll\n'
else
    printf '  FAIL auth help printed %d times\n' "$n_auth"
    FAILED=$((FAILED + 1))
fi
refute "$MODLOG" 'never writes to Plex' 'Plex public port is now'

#------------------------------------------------------------------------------
say "Scenario 4: port forwarding not ready (HTTP 200, port 0) - must leave Plex alone"
run_scenario pfsmoke/caddyfile-gluetun-zero pfsmoke/caddyfile-plex 10
dump "$MODLOG"
expect "$MODLOG" 'reports not-ready' 'gluetun reports no forwarded port yet'
expect "$MODLOG" 'says it is leaving Plex unchanged' 'leaving Plex.s public port unchanged'
refute "$MODLOG" 'no write attempted' 'updating Plex'
refute "$PLEXLOG" 'no PUT reached Plex' '"method":"PUT"'

#------------------------------------------------------------------------------
say "Scenario 5: multi-port provider (unsorted, no \"port\" key)"
run_scenario pfsmoke/caddyfile-gluetun-multi pfsmoke/caddyfile-plex 10
expect "$MODLOG" 'picks the lowest and shows the whole set' 'forwarded port: 1024 \(all: 1024 2048 4096\)'
expect "$MODLOG" 'publishes the lowest' 'ManualPortMappingPort 32400->1024'

say "Scenario 5b: same, with GLUETUN_PF_PORT_INDEX=2"
run_scenario pfsmoke/caddyfile-gluetun-multi pfsmoke/caddyfile-plex 10 GLUETUN_PF_PORT_INDEX=2
expect "$MODLOG" 'honours the index' 'forwarded port: 4096'
expect "$MODLOG" 'publishes the selected port' 'ManualPortMappingPort 32400->4096'

#------------------------------------------------------------------------------
say "Scenario 6: Plex rejects the token (401)"
run_scenario pfsmoke/caddyfile-gluetun-ok pfsmoke/caddyfile-plex-401 10
dump "$MODLOG"
expect "$MODLOG" 'reports the rejection' 'rejected our token while reading settings'
expect "$MODLOG" 'keeps running afterwards' 'gluetun forwarded port'

#------------------------------------------------------------------------------
say "Scenario 7: Plex rate-limits the write (429)"
run_scenario pfsmoke/caddyfile-gluetun-ok pfsmoke/caddyfile-plex-429 20
dump "$MODLOG"
expect "$MODLOG" 'detects the rate limit' 'rate-limited the settings update \(429\)'
expect "$MODLOG" 'backs off for 60s' 'retrying in 60s'
n429=$(grep -c '"method":"PUT"' <<<"$PLEXLOG")
if ((n429 <= 2)); then
    printf '  ok   backoff actually suppressed retries (%d PUTs in 20s)\n' "$n429"
else
    printf '  FAIL backoff did not hold: %d PUTs in 20s\n' "$n429"
    FAILED=$((FAILED + 1))
fi

#------------------------------------------------------------------------------
say "Scenario 8: Plex rejects a preference name (400)"
run_scenario pfsmoke/caddyfile-gluetun-ok pfsmoke/caddyfile-plex-400 12
expect "$MODLOG" 'reports the bad request with the query string' '400 Bad Request'
expect "$MODLOG" 'blames a mod bug or API change' 'mod bug or a Plex API change'

#------------------------------------------------------------------------------
say "Scenario 9: gluetun unreachable, then recovers"
docker rm -f pfs-gt pfs-plex pfs-mod >/dev/null 2>&1
docker run -d --name pfs-plex --network "${NET}" --network-alias plex-stub pfsmoke/caddyfile-plex >/dev/null
sleep 2
docker run -d --name pfs-mod --network "${NET}" \
    -e GLUETUN_PF_CONTROL_URL=http://gluetun-stub:8000 \
    -e GLUETUN_PF_PLEX_URL=http://plex-stub:32400 \
    -e GLUETUN_PF_PLEX_TOKEN=stub-token \
    -e GLUETUN_PF_INTERVAL=5 -e GLUETUN_PF_RETRY_INTERVAL=2 \
    pfsmoke/runner bash /run.sh >/dev/null
sleep 6
MODLOG="$(docker logs pfs-mod 2>&1)"
expect "$MODLOG" 'reports gluetun unreachable with a usable hint' 'could not resolve host|connection refused|timed out'
expect "$MODLOG" 'suggests the right URL form' 'network_mode: service:gluetun'
docker run -d --name pfs-gt --network "${NET}" --network-alias gluetun-stub pfsmoke/caddyfile-gluetun-ok >/dev/null
sleep 10
MODLOG="$(docker logs pfs-mod 2>&1)"
expect "$MODLOG" 'recovers without a restart' 'gluetun forwarded port: 54321'
expect "$MODLOG" 'and converges Plex' 'Plex public port is now 54321'

#------------------------------------------------------------------------------
say "Scenario 10: GLUETUN_PF_ENABLED=false makes it inert"
run_scenario pfsmoke/caddyfile-gluetun-ok pfsmoke/caddyfile-plex 6 GLUETUN_PF_ENABLED=false
dump "$MODLOG"
expect "$MODLOG" 'says it is inert' 'will stay inert'
refute "$MODLOG" 'does not start the loop' 'starting'
# finish must return 125 so s6 leaves the service permanently down
code=$(docker run --rm -e GLUETUN_PF_ENABLED=false pfsmoke/runner bash /finish.sh 0 0 >/dev/null 2>&1; echo $?)
if [[ ${code} == 125 ]]; then
    printf '  ok   finish returns 125 when disabled (s6 keeps it down)\n'
else
    printf '  FAIL finish returned %s, expected 125\n' "${code}"
    FAILED=$((FAILED + 1))
fi
code=$(docker run --rm pfsmoke/runner bash /finish.sh 0 0 >/dev/null 2>&1; echo $?)
if [[ ${code} == 0 ]]; then
    printf '  ok   finish returns 0 on a clean exit when enabled\n'
else
    printf '  FAIL finish returned %s on clean exit, expected 0\n' "${code}"
    FAILED=$((FAILED + 1))
fi

#------------------------------------------------------------------------------
say "Scenario 11: GLUETUN_PF_MANAGE_REMOTE_ACCESS=false leaves the publish switch alone"
run_scenario pfsmoke/caddyfile-gluetun-ok pfsmoke/caddyfile-plex 10 GLUETUN_PF_MANAGE_REMOTE_ACCESS=false
expect "$PLEXLOG" 'PUT omits PublishServerOnPlexOnlineKey' 'ManualPortMappingMode=1&ManualPortMappingPort=54321'
refute "$MODLOG" 'does not mention the publish switch' 'PublishServerOnPlexOnlineKey'
expect "$MODLOG" 'says the switch is left alone' 'remote access switch   : left alone'

#------------------------------------------------------------------------------
say "Scenario 12: the netns watchdog is off unless it is asked for"
# The whole safety promise of the feature: someone already pulling :latest must
# see byte-identical behaviour until they set the flag.
run_scenario pfsmoke/caddyfile-gluetun-ok pfsmoke/caddyfile-plex 12 \
    GLUETUN_PF_NETNS_SYSFS=/dead-netns
refute "$MODLOG" 'says nothing about a watchdog' 'netns watchdog'
refute "$MODLOG" 'does not report a strike' 'stranded in a dead network namespace'
expect "$MODLOG" 'and still does its actual job' 'Plex public port is now 54321'
if [[ $(docker inspect -f '{{.State.Running}}' pfs-mod) == true ]]; then
    printf '  ok   still running -- a dead namespace alone halts nothing\n'
else
    printf '  FAIL the mod exited with the watchdog unset\n'
    FAILED=$((FAILED + 1))
fi

#------------------------------------------------------------------------------
say "Scenario 12b: dry run reaches the decision and refuses to act on it"
# The halt itself replaces PID 1 of a real s6 container and cannot be reached
# from here, which is exactly why the dry-run flag exists.
run_scenario pfsmoke/caddyfile-gluetun-ok pfsmoke/caddyfile-plex 16 \
    GLUETUN_PF_NETNS_SYSFS=/dead-netns \
    GLUETUN_PF_NETNS_WATCHDOG=true GLUETUN_PF_NETNS_WATCHDOG_DRY_RUN=true \
    GLUETUN_PF_NETNS_WATCHDOG_GRACE=0 GLUETUN_PF_NETNS_WATCHDOG_STRIKES=2
dump "$MODLOG"
expect "$MODLOG" 'announces itself as a dry run' 'netns watchdog *: DRY RUN'
expect "$MODLOG" 'counts a strike' 'stranded in a dead network namespace \(strike 1/2\)'
expect "$MODLOG" 'reaches the threshold' 'strike 2/2'
expect "$MODLOG" 'says what it would have done' 'DRY RUN: would halt the container now with exit 70'
if [[ $(docker inspect -f '{{.State.Running}}' pfs-mod) == true ]]; then
    printf '  ok   still running -- dry run halts nothing\n'
else
    printf '  FAIL dry run halted the container\n'
    FAILED=$((FAILED + 1))
fi

#------------------------------------------------------------------------------
say "Scenario 13: SIGTERM shuts down promptly instead of waiting out the poll"
docker rm -f pfs-mod >/dev/null 2>&1
docker run -d --name pfs-mod --network "${NET}" \
    -e GLUETUN_PF_CONTROL_URL=http://gluetun-stub:8000 \
    -e GLUETUN_PF_PLEX_URL=http://plex-stub:32400 \
    -e GLUETUN_PF_PLEX_TOKEN=stub-token \
    -e GLUETUN_PF_INTERVAL=300 -e GLUETUN_PF_RETRY_INTERVAL=2 \
    pfsmoke/runner bash /run.sh >/dev/null
sleep 6
start=$(date +%s)
docker stop -t 30 pfs-mod >/dev/null
elapsed=$(($(date +%s) - start))
MODLOG="$(docker logs pfs-mod 2>&1)"
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
