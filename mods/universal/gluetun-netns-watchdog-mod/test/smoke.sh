#!/usr/bin/env bash
# shellcheck shell=bash
#
# Exercise the real longrun in a throwaway container. A baked fake sysfs lets us
# model the exact orphaned shape (only `lo`) without changing the runner's real
# network namespace or granting it capabilities.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVC="${REPO}/root/etc/s6-overlay/s6-rc.d/svc-mod-universal-gluetun-netns-watchdog-mod"
WORK="$(mktemp -d)"
NAME="netns-watchdog-smoke-$$"
IMAGE="local/universal-gluetun-netns-watchdog-smoke:$$"
FAILED=0

# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
cleanup() {
    # ShellCheck 0.9 reports trap callbacks as unreachable (SC2317).
    # shellcheck disable=SC2317
    docker rm -f "${NAME}" >/dev/null 2>&1
    # shellcheck disable=SC2317
    docker image rm -f "${IMAGE}" >/dev/null 2>&1
    # shellcheck disable=SC2317
    rm -rf "${WORK}"
}
trap cleanup EXIT

cp "${SVC}/run" "${WORK}/run"
cp "${REPO}/../../../shared/mod-gluetun-portforward/netns-watchdog.sh" "${WORK}/netns-watchdog.sh"
printf '%s\n' \
    'FROM bash:5' \
    'RUN mkdir -p /dead-netns /almost-netns && touch /dead-netns/lo /almost-netns/lo /almost-netns/bonding_masters' \
    'COPY run /run.sh' \
    'COPY netns-watchdog.sh /usr/local/lib/mod-gluetun-portforward/netns-watchdog.sh' \
    >"${WORK}/Dockerfile"
docker build -q -t "${IMAGE}" "${WORK}" >/dev/null

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
say() { printf '\n### %s\n' "$1"; }

say 'ordinary namespace stays healthy'
docker run -d --name "${NAME}" \
    -e GLUETUN_NETNS_WATCHDOG_INTERVAL=1 \
    -e GLUETUN_NETNS_WATCHDOG_GRACE=0 \
    "${IMAGE}" bash /run.sh >/dev/null
sleep 3
LOG="$(docker logs "${NAME}" 2>&1)"
expect "${LOG}" 'service starts armed' 'watchdog +: armed'
refute "${LOG}" 'eth0 prevents a false alarm' 'looks stranded'
if [[ $(docker inspect -f '{{.State.Running}}' "${NAME}") == true ]]; then
    printf '  ok   service remains running\n'
else
    printf '  FAIL service stopped in a healthy namespace\n'
    FAILED=$((FAILED + 1))
fi
docker stop -t 3 "${NAME}" >/dev/null
LOG="$(docker logs "${NAME}" 2>&1)"
expect "${LOG}" 'SIGTERM is handled cleanly' 'shutting down'
docker rm "${NAME}" >/dev/null

say 'dead namespace reaches the decision in dry-run mode'
docker run -d --name "${NAME}" \
    -e GLUETUN_NETNS_WATCHDOG_SYSFS=/dead-netns \
    -e GLUETUN_NETNS_WATCHDOG_INTERVAL=1 \
    -e GLUETUN_NETNS_WATCHDOG_GRACE=0 \
    -e GLUETUN_NETNS_WATCHDOG_STRIKES=2 \
    -e GLUETUN_NETNS_WATCHDOG_DRY_RUN=true \
    "${IMAGE}" bash /run.sh >/dev/null
sleep 4
LOG="$(docker logs "${NAME}" 2>&1)"
expect "${LOG}" 'first failed scan is counted' 'strike 1/2'
expect "${LOG}" 'second scan reaches the action threshold' 'strike 2/2'
expect "${LOG}" 'dry run never halts the container' 'DRY RUN: would halt'
expect "${LOG}" 'the log names the standalone arming variable' \
    'GLUETUN_NETNS_WATCHDOG_DRY_RUN=false'
if [[ $(docker inspect -f '{{.State.Running}}' "${NAME}") == true ]]; then
    printf '  ok   dry-run container remains running\n'
else
    printf '  FAIL dry-run container stopped\n'
    FAILED=$((FAILED + 1))
fi
docker rm -f "${NAME}" >/dev/null

say 'bonding_masters is not mistaken for an interface'
docker run -d --name "${NAME}" \
    -e GLUETUN_NETNS_WATCHDOG_SYSFS=/almost-netns \
    -e GLUETUN_NETNS_WATCHDOG_INTERVAL=1 \
    -e GLUETUN_NETNS_WATCHDOG_GRACE=0 \
    -e GLUETUN_NETNS_WATCHDOG_STRIKES=1 \
    -e GLUETUN_NETNS_WATCHDOG_DRY_RUN=true \
    "${IMAGE}" bash /run.sh >/dev/null
sleep 2
LOG="$(docker logs "${NAME}" 2>&1)"
expect "${LOG}" 'control file does not hide the dead namespace' 'strike 1/1'
docker rm -f "${NAME}" >/dev/null

say 'the mod can be disabled without error'
set +e
LOG="$(docker run --rm -e GLUETUN_NETNS_WATCHDOG_ENABLED=false "${IMAGE}" bash /run.sh 2>&1)"
RC=$?
set -e
if [[ ${RC} == 0 ]]; then
    printf '  ok   disabled run exits cleanly\n'
else
    printf '  FAIL disabled run exited %s\n' "${RC}"
    FAILED=$((FAILED + 1))
fi
expect "${LOG}" 'disabled state is explicit' 'disabled by GLUETUN_NETNS_WATCHDOG_ENABLED'

printf '\n%d smoke failure(s)\n' "${FAILED}"
exit "${FAILED}"
