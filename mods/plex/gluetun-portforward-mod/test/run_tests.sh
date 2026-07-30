#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for the pure functions in the mod's ./run script. No Docker, no
# VPN, no Plex, no network.
#
# ./run is sourced with GLUETUN_PF_LIB_ONLY=1, which makes it define everything
# and run nothing.
#
# Needs bash 4+ (declare -A, mapfile, ${VAR,,}). macOS ships bash 3.2, so:
#
#   docker run --rm -v "$PWD:/mnt" -w /mnt bash:5 bash test/run_tests.sh
#
# Run it a second time with jq masked out of PATH to exercise the sed fallback:
#
#   docker run --rm -v "$PWD:/mnt" -w /mnt -e NO_JQ=1 bash:5 bash test/run_tests.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="${HERE}/../root/etc/s6-overlay/s6-rc.d/svc-mod-plex-gluetun-portforward-mod/run"

if [[ ${NO_JQ:-0} == 1 ]]; then
    # Mask jq to exercise the sed/tr fallback in extract_ports.
    #
    # Shadow the `command` builtin rather than editing PATH: on Alpine jq lives
    # in /usr/bin alongside sed, grep, sort and tr, so dropping its directory
    # from PATH takes the rest of the script's tools with it. This targets
    # exactly the `command -v jq` guards the mod uses and nothing else.
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
    if ! command -v sed >/dev/null 2>&1; then
        echo "FATAL: masking jq also broke sed" >&2
        exit 1
    fi
    MODE="no-jq"
else
    MODE="with-jq"
fi

# Resolve the source path relative to this script rather than the caller's cwd,
# so `shellcheck -x` can follow it and see which globals ./run consumes.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../root/etc/s6-overlay/s6-rc.d/svc-mod-plex-gluetun-portforward-mod/run
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

eq() { # eq <name> <expected> <actual>
    if [[ $2 == "$3" ]]; then ok "$1"; else no "$1" "$2" "$3"; fi
}

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
    PORT_INDEX_WARNED=0
    gluetun_select_port "${json}"
    local rc=$?
    eq "${name} [rc]" "${want_rc}" "${rc}"
    eq "${name} [port]" "${want_port}" "${GT_PORT}"
}

sel 'v<=3.40.4 single           {"port":54321}' \
    '{"port":54321}' 0 54321
sel 'v<=3.40.4 not ready        {"port":0}' \
    '{"port":0}' 1 ''
sel 'v3.39-3.41.1 multi, no key {"ports":[54321,54322]}' \
    '{"ports":[54321,54322]}' 0 54321
sel 'v3.41.2 both keys          {"port":54321,"ports":[54321]}' \
    '{"port":54321,"ports":[54321]}' 0 54321
sel 'not ready, normal          {"port":0,"ports":[]}' \
    '{"port":0,"ports":[]}' 1 ''
sel 'not ready, startup window  {"port":0,"ports":null}' \
    '{"port":0,"ports":null}' 1 ''
sel 'Perfect Privacy, unsorted  {"ports":[4096,1024,2048]}' \
    '{"ports":[4096,1024,2048]}' 0 1024
sel 'PORT_INDEX=2 selects third' \
    '{"ports":[4096,1024,2048]}' 0 4096 2
sel 'PORT_INDEX=9 falls back to lowest' \
    '{"ports":[4096,1024,2048]}' 0 1024 9
sel 'empty object               {}' \
    '{}' 1 ''
sel 'zero filtered out          {"ports":[0]}' \
    '{"ports":[0]}' 1 ''
sel 'out of range filtered      {"ports":[99999]}' \
    '{"ports":[99999]}' 1 ''
sel 'non-JSON is NOT "port 0"   <html>401</html>' \
    '<html>401</html>' 2 ''
sel 'empty body' \
    '' 2 ''

PORT_INDEX=0

# GT_ALL should carry the whole sorted set, which is what gets logged so the
# user can see what GLUETUN_PF_PORT_INDEX could pick.
gluetun_select_port '{"ports":[4096,1024,2048]}'
eq 'GT_ALL is the sorted set' '1024 2048 4096' "${GT_ALL}"

#------------------------------------------------------------------------------
section "plex_pref: parsing GET /:/prefs"
#------------------------------------------------------------------------------
PREFS_COMPACT='<?xml version="1.0" encoding="UTF-8"?><MediaContainer size="3"><Setting id="ManualPortMappingMode" label="Manually specify public port" summary="" type="bool" default="false" value="1" hidden="false" advanced="true" group="network" /><Setting id="ManualPortMappingPort" label="External port" summary="" type="int" default="32400" value="54321" hidden="false" advanced="true" group="network" /><Setting id="PublishServerOnPlexOnlineKey" label="Enable Remote Access" type="bool" default="false" value="1" group="network" /></MediaContainer>'

eq 'compact: mode' '1' "$(plex_pref "${PREFS_COMPACT}" ManualPortMappingMode)"
eq 'compact: port' '54321' "$(plex_pref "${PREFS_COMPACT}" ManualPortMappingPort)"
eq 'compact: publish' '1' "$(plex_pref "${PREFS_COMPACT}" PublishServerOnPlexOnlineKey)"
eq 'absent setting returns empty, not a neighbour value' \
    '' "$(plex_pref "${PREFS_COMPACT}" NoSuchSetting)"

PREFS_PRETTY='<MediaContainer size="2">
  <Setting id="ManualPortMappingMode"
           label="Manually specify public port"
           type="bool"
           default="false"
           value="0" />
  <Setting id="ManualPortMappingPort"
           type="int"
           value="12345" />
</MediaContainer>'
eq 'pretty-printed: mode' '0' "$(plex_pref "${PREFS_PRETTY}" ManualPortMappingMode)"
eq 'pretty-printed: port' '12345' "$(plex_pref "${PREFS_PRETTY}" ManualPortMappingPort)"

PREFS_ENUM='<MediaContainer><Setting id="secureConnections" type="enum" default="1" value="1" enumValues="0:Required|1:Preferred|2:Disabled" /><Setting id="ManualPortMappingPort" type="int" value="41234" /></MediaContainer>'
eq 'enumValues= is not mistaken for value=' '1' "$(plex_pref "${PREFS_ENUM}" secureConnections)"
eq 'setting after an enum still parses' '41234' "$(plex_pref "${PREFS_ENUM}" ManualPortMappingPort)"

PREFS_ENTITY='<MediaContainer><Setting id="FriendlyName" type="text" value="Bob&quot;s Server" /><Setting id="ManualPortMappingPort" type="int" value="33333" /></MediaContainer>'
eq 'value containing &quot; is captured whole' 'Bob&quot;s Server' \
    "$(plex_pref "${PREFS_ENTITY}" FriendlyName)"
eq 'parsing continues past an entity-bearing value' '33333' \
    "$(plex_pref "${PREFS_ENTITY}" ManualPortMappingPort)"

PREFS_PREFIX='<MediaContainer><Setting id="ManualPortMappingPortRange" type="text" value="BOGUS" /><Setting id="ManualPortMappingPort" type="int" value="44444" /></MediaContainer>'
eq 'id match is exact, not a prefix' '44444' \
    "$(plex_pref "${PREFS_PREFIX}" ManualPortMappingPort)"

#------------------------------------------------------------------------------
section "read_token"
#------------------------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# A real Preferences.xml is one long line of attributes on a self-closing tag.
printf '%s' '<?xml version="1.0" encoding="utf-8"?>
<Preferences MachineIdentifier="68806dc3" PlexOnlineToken="tok3nAAAAAAAAAAAAAAA" PlexOnlineUsername="bob" ManualPortMappingMode="1" ManualPortMappingPort="32400"/>' >"${TMP}/claimed.xml"
printf '%s' '<?xml version="1.0" encoding="utf-8"?>
<Preferences MachineIdentifier="68806dc3" PlexOnlineToken="" ManualPortMappingMode="0"/>' >"${TMP}/halfclaimed.xml"
printf '%s' '<?xml version="1.0" encoding="utf-8"?>
<Preferences MachineIdentifier="68806dc3" ManualPortMappingMode="0"/>' >"${TMP}/unclaimed.xml"
printf '%s' '<?xml version="1.0" encoding="utf-8"?>
<Preferences MachineIdentifier="68806dc3" PlexOnlineTok' >"${TMP}/truncated.xml"

tok() { # tok <name> <file> <want-rc> <want-token>
    TOKEN=""
    TOKEN_OVERRIDE=""
    PREFS_FILE="$2"
    read_token
    local rc=$?
    eq "$1 [rc]" "$3" "${rc}"
    eq "$1 [token]" "$4" "${TOKEN}"
}

tok 'claimed server yields the token' "${TMP}/claimed.xml" 0 'tok3nAAAAAAAAAAAAAAA'
tok 'PlexOnlineToken="" is treated as absent' "${TMP}/halfclaimed.xml" 1 ''
tok 'unclaimed server has no token' "${TMP}/unclaimed.xml" 1 ''
tok 'file truncated mid-attribute is not a token' "${TMP}/truncated.xml" 1 ''
tok 'missing file is not fatal' "${TMP}/nope.xml" 1 ''

TOKEN=""
TOKEN_OVERRIDE="override-t0ken"
PREFS_FILE="${TMP}/unclaimed.xml"
read_token
eq 'GLUETUN_PF_PLEX_TOKEN wins over the file' 'override-t0ken' "${TOKEN}"
eq 'token source is reported as the env var' 'GLUETUN_PF_PLEX_TOKEN' "${TOKEN_SOURCE}"
TOKEN_OVERRIDE=""

#------------------------------------------------------------------------------
section "small predicates"
#------------------------------------------------------------------------------
eq 'normalise_url adds a scheme' 'http://gluetun:8000' "$(normalise_url 'gluetun:8000')"
eq 'normalise_url strips trailing slashes' 'http://localhost:8000' "$(normalise_url 'http://localhost:8000///')"
eq 'normalise_url keeps https' 'https://plex.example:32400' "$(normalise_url 'https://plex.example:32400/')"
eq 'normalise_url keeps a bracketed v6 literal' 'http://[::1]:32400' "$(normalise_url 'http://[::1]:32400')"

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
eq 'curl_hint 99' 'curl exit 99' "$(curl_hint 99)"

#------------------------------------------------------------------------------
section "state(): one log line per transition"
#------------------------------------------------------------------------------
_st=()
if state k a; then ok 'first value is a transition'; else no 'first value is a transition' 0 1; fi
if state k a; then no 'repeat is not a transition' 1 0; else ok 'repeat is not a transition'; fi
if state k b; then ok 'change is a transition'; else no 'change is a transition' 0 1; fi
if state k a; then ok 'change back is a transition'; else no 'change back is a transition' 0 1; fi

#------------------------------------------------------------------------------
section "configure(): clamping instead of failing"
#------------------------------------------------------------------------------
clamp() { # clamp <name> <var> <env-assignment...> -> expected value in $4
    local name=$1 var=$2 want=$3
    shift 3
    local out
    # The single quotes are deliberate: this body must reach the child bash
    # literally, with the script path and variable name passed positionally.
    # shellcheck disable=SC2016
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
clamp 'INTERVAL 1 clamps to 60' INTERVAL 60 GLUETUN_PF_INTERVAL=1
clamp 'INTERVAL 30 is honoured' INTERVAL 30 GLUETUN_PF_INTERVAL=30
clamp 'RETRY_INTERVAL default' RETRY_INTERVAL 10
clamp 'RETRY_INTERVAL 0 clamps to 10' RETRY_INTERVAL 10 GLUETUN_PF_RETRY_INTERVAL=0
clamp 'TIMEOUT bad value clamps to 10' TIMEOUT 10 GLUETUN_PF_TIMEOUT=nope
clamp 'PORT_INDEX bad value clamps to 0' PORT_INDEX 0 GLUETUN_PF_PORT_INDEX=first
clamp 'CONTROL_URL default' CONTROL_URL http://localhost:8000
clamp 'CONTROL_URL normalised' CONTROL_URL http://gluetun:8000 GLUETUN_PF_CONTROL_URL=gluetun:8000/
clamp 'PLEX_URL default' PLEX_URL http://localhost:32400
clamp 'auth desc: none' GT_AUTH_DESC none
clamp 'auth desc: apikey' GT_AUTH_DESC 'X-API-Key header' GLUETUN_PF_APIKEY=abc
clamp 'auth desc: basic' GT_AUTH_DESC "HTTP basic as 'u'" \
    GLUETUN_PF_USERNAME=u GLUETUN_PF_PASSWORD=p
clamp 'apikey wins over basic' GT_AUTH_DESC 'X-API-Key header' \
    GLUETUN_PF_APIKEY=abc GLUETUN_PF_USERNAME=u GLUETUN_PF_PASSWORD=p

#------------------------------------------------------------------------------
printf '\n'
if ((FAIL)); then
    printf '%d passed, %d FAILED (%s)\n' "${PASS}" "${FAIL}" "${MODE}"
    printf '  - %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
printf '%d passed, 0 failed (%s)\n' "${PASS}" "${MODE}"
