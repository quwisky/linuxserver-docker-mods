#!/usr/bin/env bash
# shellcheck shell=bash
#
# Focused tests for the standalone service wrapper. The shared watchdog's full
# safety matrix is covered by the Plex and qBittorrent suites; these checks make
# sure the universal mod maps its neutral interface correctly and drives that
# helper as intended.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="${HERE}/../root/etc/s6-overlay/s6-rc.d/svc-mod-universal-gluetun-netns-watchdog-mod"
HELPER="${HERE}/../../../../shared/mod-gluetun-portforward/netns-watchdog.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${TMP}/live" "${TMP}/dead"
touch "${TMP}/live/lo" "${TMP}/live/eth0" "${TMP}/dead/lo"

export GLUETUN_NETNS_WATCHDOG_LIB="${HELPER}"
export GLUETUN_NETNS_WATCHDOG_LIB_ONLY=1
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../root/etc/s6-overlay/s6-rc.d/svc-mod-universal-gluetun-netns-watchdog-mod/run
source "${MOD}/run"

PASS=0
FAIL=0
FAILED_NAMES=()
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
no() {
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$1")
    printf '  FAIL %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"
}
eq() { if [[ $2 == "$3" ]]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
has() { if [[ $2 == *"$3"* ]]; then ok "$1"; else no "$1" "a string containing '$3'" "$2"; fi; }
section() { printf '\n== %s ==\n' "$1"; }

section "defaults and the standalone environment"
unset GLUETUN_NETNS_WATCHDOG_ENABLED GLUETUN_NETNS_WATCHDOG_DRY_RUN \
    GLUETUN_NETNS_WATCHDOG_STRIKES GLUETUN_NETNS_WATCHDOG_GRACE \
    GLUETUN_NETNS_WATCHDOG_EXIT_CODE GLUETUN_NETNS_WATCHDOG_MAX_HALTS \
    GLUETUN_NETNS_WATCHDOG_INTERVAL GLUETUN_NETNS_WATCHDOG_SYSFS
configure
eq 'enabled when the mod is installed' 1 "${NETNS_WATCHDOG}"
eq 'dry run is off' 0 "${NETNS_DRY_RUN}"
eq 'four consecutive misses' 4 "${NETNS_STRIKES_MAX}"
eq 'sixty-second startup grace' 60 "${NETNS_GRACE}"
eq 'non-zero container exit' 70 "${NETNS_EXIT_CODE}"
eq 'three failed halt attempts' 3 "${NETNS_MAX_HALTS}"
eq 'fifteen-second poll' 15 "${POLL_INTERVAL}"
eq 'standalone state cannot collide with a port-sync mod' \
    /run/mod-universal-gluetun-netns-watchdog "${NETNS_STATE_DIR}"

section "GLUETUN_PF variables cannot configure the standalone service"
export GLUETUN_PF_NETNS_WATCHDOG=0
export GLUETUN_PF_NETNS_WATCHDOG_DRY_RUN=true
GLUETUN_NETNS_WATCHDOG_ENABLED=true
GLUETUN_NETNS_WATCHDOG_DRY_RUN=false
configure
eq 'generic enabled wins over GLUETUN_PF disabled' 1 "${NETNS_WATCHDOG}"
eq 'generic dry-run wins over GLUETUN_PF dry-run' 0 "${NETNS_DRY_RUN}"

section "invalid values clamp safely"
GLUETUN_NETNS_WATCHDOG_INTERVAL=instant
GLUETUN_NETNS_WATCHDOG_STRIKES=0
GLUETUN_NETNS_WATCHDOG_GRACE=soon
GLUETUN_NETNS_WATCHDOG_EXIT_CODE=0
GLUETUN_NETNS_WATCHDOG_MAX_HALTS=many
configure >"${TMP}/invalid-values.log"
out="$(<"${TMP}/invalid-values.log")"
eq 'bad interval falls back' 15 "${POLL_INTERVAL}"
eq 'bad strike count falls back' 4 "${NETNS_STRIKES_MAX}"
eq 'bad grace falls back' 60 "${NETNS_GRACE}"
eq 'zero exit code falls back' 70 "${NETNS_EXIT_CODE}"
eq 'bad halt cap falls back' 3 "${NETNS_MAX_HALTS}"
has 'the interval error names the public variable' "${out}" GLUETUN_NETNS_WATCHDOG_INTERVAL

section "a dead namespace reaches the shared halt decision"
GLUETUN_NETNS_WATCHDOG_INTERVAL=1
GLUETUN_NETNS_WATCHDOG_STRIKES=2
GLUETUN_NETNS_WATCHDOG_GRACE=0
GLUETUN_NETNS_WATCHDOG_EXIT_CODE=70
GLUETUN_NETNS_WATCHDOG_MAX_HALTS=3
GLUETUN_NETNS_WATCHDOG_SYSFS="${TMP}/dead"
configure
NETNS_STATE_DIR="${TMP}/state"
export NETNS_BOOT_TOKEN=unit-test
HALTS=0
netns_watchdog_halt() { HALTS=$((HALTS + 1)); }
SECONDS=1
netns_watchdog_check >/dev/null
eq 'first miss is one strike' 1 "${NETNS_STRIKES}"
eq 'first miss does not halt' 0 "${HALTS}"
netns_watchdog_check >/dev/null
eq 'second consecutive miss requests one halt' 1 "${HALTS}"
eq 'the halt attempt is persisted' 1 "$(netns_halt_attempts)"

section "a live interface resets a partial failure"
NETNS_SYSFS="${TMP}/dead"
NETNS_STRIKES=0
netns_clear_halt_attempts
netns_watchdog_check >/dev/null
NETNS_SYSFS="${TMP}/live"
netns_watchdog_check >"${TMP}/recovery.log"
out="$(<"${TMP}/recovery.log")"
eq 'strike count resets' 0 "${NETNS_STRIKES}"
eq 'a natural recovery clears the halt budget' 0 "$(netns_halt_attempts)"
has 'recovery is visible in the logs' "${out}" 'network namespace recovered'

section "dry run uses the standalone variable name"
GLUETUN_NETNS_WATCHDOG_DRY_RUN=true
GLUETUN_NETNS_WATCHDOG_STRIKES=1
GLUETUN_NETNS_WATCHDOG_SYSFS="${TMP}/dead"
configure
SECONDS=1
out="$(netns_watchdog_check)"
has 'dry run announces the decision' "${out}" 'DRY RUN: would halt'
has 'the arming hint names the generic variable' "${out}" \
    'GLUETUN_NETNS_WATCHDOG_DRY_RUN=false'

section "the finish policy"
set +e
GLUETUN_NETNS_WATCHDOG_ENABLED=false bash "${MOD}/finish" 0 0 >/dev/null
rc_disabled=$?
GLUETUN_NETNS_WATCHDOG_ENABLED=true bash "${MOD}/finish" 78 0 >/dev/null
rc_missing=$?
GLUETUN_NETNS_WATCHDOG_ENABLED=true bash "${MOD}/finish" 0 0 >/dev/null
rc_clean=$?
set -e
eq 'disabled service is left down' 125 "${rc_disabled}"
eq 'missing helper is left down' 125 "${rc_missing}"
eq 'a clean ordinary exit remains restartable' 0 "${rc_clean}"

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
if ((FAIL)); then
    printf 'failed checks:\n'
    printf '  - %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
