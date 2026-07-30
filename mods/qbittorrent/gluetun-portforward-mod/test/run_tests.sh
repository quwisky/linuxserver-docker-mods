#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for the pure functions in the mod's ./run script. No Docker, no
# VPN, no qBittorrent, no network.
#
# ./run is sourced with GLUETUN_PF_LIB_ONLY=1, which makes it define everything
# and run nothing.
#
# Needs bash 4+ (declare -A, mapfile, ${VAR,,}). macOS ships bash 3.2, so:
#
#   docker run --rm -v "$PWD:/mnt" -w /mnt bash:5 sh -c 'apk add -q jq && bash test/run_tests.sh'
#
# Run it a second time with jq masked to exercise the sed fallbacks:
#
#   NO_JQ=1 bash test/run_tests.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="${HERE}/../root/etc/s6-overlay/s6-rc.d/svc-mod-qbittorrent-gluetun-portforward-mod/run"

if [[ ${NO_JQ:-0} == 1 ]]; then
    # Shadow the `command` builtin rather than editing PATH: on Alpine jq lives
    # in /usr/bin alongside sed, grep and sort, so dropping its directory from
    # PATH takes the rest of the script's tools with it. This targets exactly
    # the `command -v jq` guards the mod uses and nothing else.
    command() {
        if [[ ${1-} == "-v" && ${2-} == "jq" ]]; then
            return 1
        fi
        builtin command "$@"
    }
    if command -v jq >/dev/null 2>&1; then
        echo "FATAL: could not mask jq" >&2
        exit 1
    fi
    MODE="no-jq"
else
    MODE="with-jq"
fi

# Resolve the source path relative to this script rather than the caller's cwd,
# so `shellcheck -x` can follow it and see which globals ./run consumes.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../root/etc/s6-overlay/s6-rc.d/svc-mod-qbittorrent-gluetun-portforward-mod/run
GLUETUN_PF_LIB_ONLY=1 source "${RUN}"

configure

PASS=0
FAIL=0
FAILED_NAMES=()

ok() {
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$1"
}
no() {
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$1")
    printf '  FAIL %s\n' "$1"
    printf '         expected: %s\n' "$2"
    printf '         actual:   %s\n' "$3"
}
eq() { if [[ $2 == "$3" ]]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
section() { printf '\n== %s (%s) ==\n' "$1" "${MODE}"; }

#------------------------------------------------------------------------------
section "gluetun_select_port: the release shape matrix"
#------------------------------------------------------------------------------
# rc 0 = usable port, 1 = valid JSON but no usable port, 2 = not JSON we grok.
# Asserting the rc split matters as much as the port: "port is 0", "list is
# empty" and "body is not JSON" must stay distinguishable.
sel() { # sel <name> <json> <want-rc> <want-port> [port-index]
    local name=$1 json=$2 want_rc=$3 want_port=$4 idx=${5:-0}
    PORT_INDEX="${idx}"
    gluetun_select_port "${json}"
    local rc=$?
    eq "${name} [rc]" "${want_rc}" "${rc}"
    eq "${name} [port]" "${want_port}" "${GT_PORT}"
}

sel 'v<=3.40.4 single           {"port":54321}' '{"port":54321}' 0 54321
sel 'v<=3.40.4 not ready        {"port":0}' '{"port":0}' 1 ''
sel 'v3.39-3.41.1 multi, no key {"ports":[54321,54322]}' '{"ports":[54321,54322]}' 0 54321
sel 'v3.41.2 both keys          {"port":54321,"ports":[54321]}' '{"port":54321,"ports":[54321]}' 0 54321
sel 'not ready, normal          {"port":0,"ports":[]}' '{"port":0,"ports":[]}' 1 ''
sel 'not ready, startup window  {"port":0,"ports":null}' '{"port":0,"ports":null}' 1 ''
sel 'Perfect Privacy, unsorted  {"ports":[4096,1024,2048]}' '{"ports":[4096,1024,2048]}' 0 1024
sel 'PORT_INDEX=2 selects third' '{"ports":[4096,1024,2048]}' 0 4096 2
sel 'PORT_INDEX=9 falls back to lowest' '{"ports":[4096,1024,2048]}' 0 1024 9
sel 'empty object               {}' '{}' 1 ''
sel 'zero filtered out          {"ports":[0]}' '{"ports":[0]}' 1 ''
sel 'out of range filtered      {"ports":[99999]}' '{"ports":[99999]}' 1 ''
sel 'non-JSON is NOT "port 0"   <html>401</html>' '<html>401</html>' 2 ''
sel 'empty body' '' 2 ''
PORT_INDEX=0

gluetun_select_port '{"ports":[4096,1024,2048]}'
eq 'GT_ALL is the sorted set' '1024 2048 4096' "${GT_ALL}"

#------------------------------------------------------------------------------
section "qBittorrent preference parsing"
#------------------------------------------------------------------------------
# A realistic slice of GET /api/v2/app/preferences. The real response has ~200
# keys; what matters is that neighbouring keys with similar names do not bleed.
PREFS='{"add_trackers":"","alt_dl_limit":10240,"listen_port":54321,"random_port":false,"upnp":false,"dht":true,"max_connec":500,"web_ui_port":8080}'

eq 'listen_port' '54321' "$(json_num "${PREFS}" listen_port)"
eq 'random_port' 'false' "$(json_bool "${PREFS}" random_port)"
eq 'upnp' 'false' "$(json_bool "${PREFS}" upnp)"
eq 'a true bool reads as true' 'true' "$(json_bool "${PREFS}" dht)"
eq 'absent key yields empty, not "null"' '' "$(json_num "${PREFS}" no_such_key)"
eq 'absent bool yields empty, not "null"' '' "$(json_bool "${PREFS}" no_such_bool)"

# The keys the mod reads must not be confused with look-alikes.
PREFS2='{"web_ui_port":8080,"listen_port":6881,"random_port":true,"upnp":true}'
eq 'listen_port is not web_ui_port' '6881' "$(json_num "${PREFS2}" listen_port)"
eq 'web_ui_port still readable' '8080' "$(json_num "${PREFS2}" web_ui_port)"
eq 'random_port true' 'true' "$(json_bool "${PREFS2}" random_port)"
eq 'upnp true' 'true' "$(json_bool "${PREFS2}" upnp)"

# Asking for a number when the value is a bool (and vice versa) must yield
# nothing rather than a misleading value.
eq 'json_num on a bool yields empty' '' "$(json_num '{"upnp":false}' upnp)"
if [[ ${MODE} == "with-jq" ]]; then
    # The sed fallback cannot make this distinction; jq can, via type filters.
    eq 'json_bool on a number yields empty' '' "$(json_bool '{"listen_port":1}' listen_port)"
fi

#------------------------------------------------------------------------------
section "small predicates"
#------------------------------------------------------------------------------
eq 'normalise_url adds a scheme' 'http://qbittorrent:8080' "$(normalise_url 'qbittorrent:8080')"
eq 'normalise_url strips trailing slashes' 'http://localhost:8080' "$(normalise_url 'http://localhost:8080///')"
eq 'normalise_url keeps https' 'https://qbt.example' "$(normalise_url 'https://qbt.example/')"
eq 'normalise_url keeps a bracketed v6 literal' 'http://[::1]:8080' "$(normalise_url 'http://[::1]:8080')"

for v in 0 false FALSE No off DISABLED disable; do
    if falsey "${v}"; then ok "falsey('${v}')"; else no "falsey('${v}')" true false; fi
    if truthy "${v}"; then no "truthy('${v}')" false true; else ok "!truthy('${v}')"; fi
done
for v in 1 true yes on enabled '' random; do
    if falsey "${v}"; then no "!falsey('${v}')" false true; else ok "!falsey('${v}')"; fi
done

if is_uint 60; then ok "is_uint(60)"; else no "is_uint(60)" true false; fi
for v in 60s -1 '' 1.5 abc; do
    if is_uint "${v}"; then no "!is_uint('${v}')" false true; else ok "!is_uint('${v}')"; fi
done

eq 'curl_hint 7' 'connection refused' "$(curl_hint 7)"
eq 'curl_hint 28' 'timed out' "$(curl_hint 28)"

#------------------------------------------------------------------------------
section "state(): one log line per transition"
#------------------------------------------------------------------------------
_st=()
if state k a; then ok 'first value is a transition'; else no 'first value is a transition' 0 1; fi
if state k a; then no 'repeat is not a transition' 1 0; else ok 'repeat is not a transition'; fi
if state k b; then ok 'change is a transition'; else no 'change is a transition' 0 1; fi

#------------------------------------------------------------------------------
section "configure(): defaults and clamping"
#------------------------------------------------------------------------------
clamp() { # clamp <name> <var> <expected> [env assignments...]
    local name=$1 var=$2 want=$3
    shift 3
    local out
    # shellcheck disable=SC2016
    # The single quotes are deliberate: this body must reach the child bash
    # literally, with the script path and variable name passed positionally.
    out="$(
        env "$@" bash -c '
            GLUETUN_PF_LIB_ONLY=1 source "$1"
            configure >/dev/null
            eval "printf %s \"\$$2\""
        ' _ "${RUN}" "${var}"
    )"
    eq "${name}" "${want}" "${out}"
}

clamp 'INTERVAL default' INTERVAL 60
clamp 'INTERVAL "60s" clamps to 60' INTERVAL 60 GLUETUN_PF_INTERVAL=60s
clamp 'INTERVAL 30 is honoured' INTERVAL 30 GLUETUN_PF_INTERVAL=30
clamp 'CONTROL_URL default' CONTROL_URL http://localhost:8000
# The image runs qbittorrent-nox with --webui-port="${WEBUI_PORT:-8080}", so the
# mod must follow WEBUI_PORT rather than assume 8080.
clamp 'QBT_URL default' QBT_URL http://localhost:8080
clamp 'QBT_URL follows WEBUI_PORT' QBT_URL http://localhost:9090 WEBUI_PORT=9090
clamp 'QBT_URL explicit override wins' QBT_URL http://qbt:1234 \
    WEBUI_PORT=9090 GLUETUN_PF_QBT_URL=http://qbt:1234
clamp 'gluetun auth desc: none' GT_AUTH_DESC none
clamp 'gluetun auth desc: apikey' GT_AUTH_DESC 'X-API-Key header' GLUETUN_PF_APIKEY=abc
clamp 'qbt auth mode: bypass' QBT_AUTH_MODE "none (relies on qBittorrent's localhost auth bypass)"
clamp 'qbt auth mode: login' QBT_AUTH_MODE "login as 'admin'" GLUETUN_PF_QBT_USERNAME=admin

#------------------------------------------------------------------------------
printf '\n'
if ((FAIL)); then
    printf '%d passed, %d FAILED (%s)\n' "${PASS}" "${FAIL}" "${MODE}"
    printf '  - %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
printf '%d passed, 0 failed (%s)\n' "${PASS}" "${MODE}"
