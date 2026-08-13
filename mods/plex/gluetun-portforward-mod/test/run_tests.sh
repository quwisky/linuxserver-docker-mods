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

# In a checkout the netns-watchdog helper still lives inside the mod's root/
# overlay; the absolute path ./run defaults to only exists once the mod has been
# applied to a container. Exported so the child shells clamp() spawns see it too.
export GLUETUN_PF_NETNS_WATCHDOG_LIB="${HERE}/../root/usr/local/lib/mod-gluetun-portforward/netns-watchdog.sh"

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
section "netns watchdog: the interface scan"
#------------------------------------------------------------------------------
# The whole feature rests on one signal: no non-loopback interface in
# /sys/class/net. NETNS_SYSFS exists so this can be pointed at a temp directory.
# Real entries there are symlinks into /sys/devices, but the scan only ever looks
# at names, so plain files are a faithful stand-in.
#
# Nested under the existing TMP rather than taking its own mktemp: a second
# `trap ... EXIT` would replace the one read_token installed above, and leak it.
NETNS_TMP="${TMP}/netns"
mkdir -p "${NETNS_TMP}"

# NETNS_SYSFS is an input to the sourced helper and is never read by this file,
# so export it: that states the relationship, and without it shellcheck reports
# every assignment below as dead (SC2034). The helper already gave it a value
# when ./run sourced it, so this cannot leave it unset.
export NETNS_SYSFS

mknet() { # mknet <label> <iface...> -> prints the directory
    local d="${NETNS_TMP}/$1"
    shift
    rm -rf "${d}"
    mkdir -p "${d}"
    local i
    for i in "$@"; do : >"${d}/${i}"; done
    printf '%s' "${d}"
}

has() { # has <name> <expected-rc> <iface...>
    local name=$1 want=$2
    shift 2
    NETNS_SYSFS="$(mknet scan "$@")"
    netns_has_network
    eq "${name}" "${want}" "$?"
}

unreadable() { # unreadable <name> <expected-rc> -- a dir we cannot enumerate
    local d="${NETNS_TMP}/blind"
    rm -rf "${d}"
    mkdir -p "${d}"
    : >"${d}/lo"
    : >"${d}/eth0"
    chmod 000 "${d}"
    NETNS_SYSFS="${d}"
    netns_has_network
    local rc=$?
    chmod 755 "${d}" # so the EXIT trap can clean up
    eq "$1" "$2" "${rc}"
}

has 'lo only -> reports no network' 1 lo
has 'lo + eth0 -> reports network' 0 lo eth0
has 'lo + tun0 -> reports network' 0 lo tun0
has 'eth0 alone -> reports network' 0 eth0
has 'an empty sysfs -> reports no network' 1
# bonding_masters is a control file the bonding module drops in this directory.
# Counting it as an interface would make the watchdog permanently blind.
has 'bonding_masters is not an interface' 1 lo bonding_masters

NETNS_SYSFS="${NETNS_TMP}/no-such-dir"
netns_has_network
eq 'a missing sysfs is not evidence, so it reports network' 0 "$?"

# "We could not look" must never be reported as "we looked and found nothing".
#
# Only meaningful as a non-root user: uid 0 bypasses the DAC check, so a mode-000
# directory is still enumerable and the assertion would pass with or without the
# -r/-x guard. Rather than let it stand as a vacuous pass, say so -- CI runs this
# suite as an unprivileged user, where it does bite.
if [[ $(id -u) -eq 0 ]]; then
    printf '  skip an unenumerable sysfs reports network -- needs a non-root uid, this is 0\n'
else
    unreadable 'an unenumerable sysfs reports network rather than "no network"' 0
fi

#------------------------------------------------------------------------------
section "netns watchdog: the halt itself"
#------------------------------------------------------------------------------
# Deliberately BEFORE the decision tests below, which replace
# netns_watchdog_halt with a stub -- so this exercises the real function.
#
# It ends in exec, so each case runs in a subshell: the exec replaces the
# subshell and this script carries on. NETNS_HALT_BIN, NETNS_EXITCODE_DIR and
# NETNS_SERVICE_DIR point it at a sandbox instead of the real s6 paths, which is
# the only reason they are variables rather than literals.
# Exported for the same reason as NETNS_SYSFS: inputs to the sourced helper that
# nothing in this file reads back, so shellcheck cannot see the use. The helper
# assigns all three unconditionally when sourced, so exporting them here cannot
# leak a sandbox path into the child shells clamp() spawns.
export NETNS_EXITCODE_DIR NETNS_SERVICE_DIR NETNS_HALT_BIN NETNS_EXIT_CODE
# Set out here rather than inside the subshell: assigning it in there and reading
# it from the stub further down is what SC2030/SC2031 exist to warn about, and
# they would be right to.
NETNS_EXIT_CODE=70

halt_case() { # halt_case <label> <halt-binary-present 0|1> -> prints its sandbox
    local dir="${NETNS_TMP}/halt-$1"
    rm -rf "${dir}"
    mkdir -p "${dir}/bin"
    printf '#!/bin/sh\necho "REAL-HALT ran"\n' >"${dir}/bin/halt"
    printf '#!/bin/sh\necho "FALLBACK s6-svscanctl $*"\n' >"${dir}/bin/s6-svscanctl"
    chmod +x "${dir}/bin/halt" "${dir}/bin/s6-svscanctl"
    (
        # Not pre-created: the halt is supposed to mkdir -p this itself.
        NETNS_EXITCODE_DIR="${dir}/results"
        NETNS_SERVICE_DIR="${dir}/service"
        if (($2)); then
            NETNS_HALT_BIN="${dir}/bin/halt"
        else
            NETNS_HALT_BIN="${dir}/bin/definitely-absent"
        fi
        PATH="${dir}/bin:${PATH}"
        netns_watchdog_halt
    ) >"${dir}/out" 2>&1
    printf '%s' "${dir}"
}

hd="$(halt_case primary 1)"
eq 'halt creates the results dir and writes the exit code' 70 "$(cat "${hd}/results/exitcode" 2>/dev/null)"
if grep -q 'REAL-HALT ran' "${hd}/out"; then
    ok 'halt execs the s6 halt binary'
else
    no 'halt execs the s6 halt binary' 'REAL-HALT ran' "$(cat "${hd}/out")"
fi

hd="$(halt_case fallback 0)"
eq 'the fallback still writes the exit code first' 70 "$(cat "${hd}/results/exitcode" 2>/dev/null)"
if grep -q 'FALLBACK s6-svscanctl -t' "${hd}/out"; then
    ok 'falls back to s6-svscanctl when the halt binary is absent'
else
    no 'falls back to s6-svscanctl when the halt binary is absent' \
        'FALLBACK s6-svscanctl -t <dir>' "$(cat "${hd}/out")"
fi
if grep -q 'is absent; falling back' "${hd}/out"; then
    ok 'and says why it fell back'
else
    no 'and says why it fell back' 'a "falling back" line' "$(cat "${hd}/out")"
fi

#------------------------------------------------------------------------------
section "netns watchdog: the halt decision"
#------------------------------------------------------------------------------
# The real halt replaces this process, so it is stubbed. Everything up to and
# including the decision is the code under test; only the exec is not.
HALTED=0
HALT_CODE=""
netns_watchdog_halt() {
    HALTED=1
    HALT_CODE="${NETNS_EXIT_CODE}"
    return 0
}

wd() { # wd <GLUETUN_PF_NETNS_* assignments...> -- configure a fresh watchdog
    HALTED=0
    HALT_CODE=""
    unset GLUETUN_PF_NETNS_WATCHDOG GLUETUN_PF_NETNS_WATCHDOG_DRY_RUN \
        GLUETUN_PF_NETNS_WATCHDOG_STRIKES GLUETUN_PF_NETNS_WATCHDOG_GRACE \
        GLUETUN_PF_NETNS_WATCHDOG_EXIT_CODE
    local a
    for a in "$@"; do export "${a?}"; done
    netns_watchdog_configure
}

# THE regression that matters. Everyone already pulling :latest has this flag
# unset, and for them the watchdog must be inert -- no strikes, no halt, nothing.
#
# GRACE=0 is load-bearing, not incidental. With the default 60s grace and a
# SECONDS of ~0 this early in the run, check() returns at the GRACE branch and
# never reaches the enabled guard -- so the assertions below would pass even if
# that guard were deleted. Pinning the grace off leaves the guard as the only
# thing that can suppress the check, which is what these two lines are for.
wd GLUETUN_PF_NETNS_WATCHDOG_GRACE=0
NETNS_SYSFS="$(mknet dead lo)"
for _ in 1 2 3 4 5 6 7 8; do netns_watchdog_check; done
eq 'flag unset: never halts, even in a dead namespace' 0 "${HALTED}"
eq 'flag unset: records no strikes' 0 "${NETNS_STRIKES}"
if netns_watchdog_enabled; then
    no 'flag unset: reports disabled' disabled enabled
else
    ok 'flag unset: reports disabled'
fi

for v in false 0 no off disabled; do
    # GRACE=0 for the same reason as above: without it the grace branch, not the
    # falsey value, is what keeps these quiet.
    wd "GLUETUN_PF_NETNS_WATCHDOG=${v}" GLUETUN_PF_NETNS_WATCHDOG_GRACE=0
    NETNS_SYSFS="$(mknet dead lo)"
    netns_watchdog_check
    netns_watchdog_check
    if ((HALTED)); then
        no "GLUETUN_PF_NETNS_WATCHDOG=${v} stays off" 0 1
    else
        ok "GLUETUN_PF_NETNS_WATCHDOG=${v} stays off"
    fi
done

# Armed: strikes must accumulate across iterations and only then halt.
wd GLUETUN_PF_NETNS_WATCHDOG=true GLUETUN_PF_NETNS_WATCHDOG_GRACE=0
NETNS_SYSFS="$(mknet dead lo)"
netns_watchdog_check
eq 'armed: first failed check is strike 1' 1 "${NETNS_STRIKES}"
eq 'armed: one strike does not halt' 0 "${HALTED}"
netns_watchdog_check
netns_watchdog_check
eq 'armed: three strikes still do not halt' 0 "${HALTED}"
netns_watchdog_check
eq 'armed: the fourth strike halts' 1 "${HALTED}"
eq 'armed: halts with the default exit code' 70 "${HALT_CODE}"

# A container whose /sys is not mounted must never be halted on that basis.
wd GLUETUN_PF_NETNS_WATCHDOG=true GLUETUN_PF_NETNS_WATCHDOG_GRACE=0 \
    GLUETUN_PF_NETNS_WATCHDOG_STRIKES=1
NETNS_SYSFS="${NETNS_TMP}/no-such-dir"
netns_watchdog_check
netns_watchdog_check
eq 'a missing sysfs never halts, whatever the strike count' 0 "${HALTED}"

# Recovery. Note the redirect rather than $( ): netns_watchdog_check mutates
# NETNS_STRIKES, and a command substitution would run it in a subshell and throw
# every assignment away.
wd GLUETUN_PF_NETNS_WATCHDOG=true GLUETUN_PF_NETNS_WATCHDOG_GRACE=0
NETNS_SYSFS="$(mknet dead lo)"
netns_watchdog_check
netns_watchdog_check
eq 'two failed checks give two strikes' 2 "${NETNS_STRIKES}"
NETNS_SYSFS="$(mknet alive lo eth0)"
netns_watchdog_check >"${NETNS_TMP}/recovered.log"
eq 'a recovered namespace resets the strikes' 0 "${NETNS_STRIKES}"
if grep -q 'recovered' "${NETNS_TMP}/recovered.log"; then
    ok 'the recovery is logged'
else
    no 'the recovery is logged' 'a line saying "recovered"' "$(cat "${NETNS_TMP}/recovered.log")"
fi
netns_watchdog_check
netns_watchdog_check
netns_watchdog_check
netns_watchdog_check
eq 'and a recovered namespace never halts' 0 "${HALTED}"

# The grace period covers container start, where the namespace is legitimately
# still being built.
wd GLUETUN_PF_NETNS_WATCHDOG=true GLUETUN_PF_NETNS_WATCHDOG_GRACE=999999 \
    GLUETUN_PF_NETNS_WATCHDOG_STRIKES=1
NETNS_SYSFS="$(mknet dead lo)"
netns_watchdog_check
netns_watchdog_check
eq 'inside the grace period nothing is counted' 0 "${NETNS_STRIKES}"
eq 'inside the grace period nothing halts' 0 "${HALTED}"

# Dry run reaches the decision and stops there.
wd GLUETUN_PF_NETNS_WATCHDOG=true GLUETUN_PF_NETNS_WATCHDOG_DRY_RUN=true \
    GLUETUN_PF_NETNS_WATCHDOG_GRACE=0 GLUETUN_PF_NETNS_WATCHDOG_STRIKES=2
NETNS_SYSFS="$(mknet dead lo)"
netns_watchdog_check
netns_watchdog_check >"${NETNS_TMP}/dryrun.log"
netns_watchdog_check
eq 'dry run reaches the threshold' 3 "${NETNS_STRIKES}"
eq 'dry run never halts' 0 "${HALTED}"
if grep -q 'DRY RUN' "${NETNS_TMP}/dryrun.log"; then
    ok 'dry run says what it would have done'
else
    no 'dry run says what it would have done' 'a DRY RUN line' "$(cat "${NETNS_TMP}/dryrun.log")"
fi

wd GLUETUN_PF_NETNS_WATCHDOG=true GLUETUN_PF_NETNS_WATCHDOG_GRACE=0 \
    GLUETUN_PF_NETNS_WATCHDOG_STRIKES=1 GLUETUN_PF_NETNS_WATCHDOG_EXIT_CODE=42
NETNS_SYSFS="$(mknet dead lo)"
netns_watchdog_check
eq 'a custom exit code is used' 42 "${HALT_CODE}"

# Load-bearing, not tidiness: wd() exports the GLUETUN_PF_NETNS_* it is given,
# and clamp() below runs `env <assignments> bash`, which inherits this
# environment. Leaving EXIT_CODE=42 exported here would fail the clamp asserting
# the default of 70.
wd

#------------------------------------------------------------------------------
section "netns watchdog: ./run survives the helper being absent"
#------------------------------------------------------------------------------
# A partial overlay must not break the poll loop. ./run defines no-op stubs when
# the helper cannot be sourced, so the mod behaves exactly as it did before this
# feature existed -- even with the flag explicitly turned on.
absent="$(
    GLUETUN_PF_NETNS_WATCHDOG_LIB=/nonexistent/netns-watchdog.sh \
        GLUETUN_PF_NETNS_WATCHDOG=true \
        bash -c '
            GLUETUN_PF_LIB_ONLY=1 source "$1"
            configure >/dev/null
            if netns_watchdog_enabled; then echo enabled; else echo disabled; fi
            netns_watchdog_check && echo check-is-a-noop
        ' _ "${RUN}" 2>&1
)"
eq 'helper absent: disabled and inert even with the flag on' \
    'disabled
check-is-a-noop' "${absent}"

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

# The watchdog's own knobs, through the mod's real configure(). Default off is
# the load-bearing one: it is what keeps existing containers byte-identical.
clamp 'netns watchdog defaults OFF' NETNS_WATCHDOG 0
clamp 'netns watchdog: empty value is off' NETNS_WATCHDOG 0 GLUETUN_PF_NETNS_WATCHDOG=
clamp 'netns watchdog: true arms it' NETNS_WATCHDOG 1 GLUETUN_PF_NETNS_WATCHDOG=true
clamp 'netns watchdog: false leaves it off' NETNS_WATCHDOG 0 GLUETUN_PF_NETNS_WATCHDOG=false
clamp 'strikes default' NETNS_STRIKES_MAX 4
clamp 'strikes 2 is honoured' NETNS_STRIKES_MAX 2 GLUETUN_PF_NETNS_WATCHDOG_STRIKES=2
clamp 'strikes "lots" clamps to 4' NETNS_STRIKES_MAX 4 GLUETUN_PF_NETNS_WATCHDOG_STRIKES=lots
clamp 'strikes 0 clamps to 4' NETNS_STRIKES_MAX 4 GLUETUN_PF_NETNS_WATCHDOG_STRIKES=0
clamp 'grace default' NETNS_GRACE 60
clamp 'grace 0 is honoured' NETNS_GRACE 0 GLUETUN_PF_NETNS_WATCHDOG_GRACE=0
clamp 'grace "60s" clamps to 60' NETNS_GRACE 60 GLUETUN_PF_NETNS_WATCHDOG_GRACE=60s
clamp 'exit code default' NETNS_EXIT_CODE 70
clamp 'exit code 42 is honoured' NETNS_EXIT_CODE 42 GLUETUN_PF_NETNS_WATCHDOG_EXIT_CODE=42
# Zero would look like a clean exit, and `restart: on-failure` would then leave
# the container stopped -- the exact opposite of the point.
clamp 'exit code 0 is rejected' NETNS_EXIT_CODE 70 GLUETUN_PF_NETNS_WATCHDOG_EXIT_CODE=0
clamp 'exit code 256 is rejected' NETNS_EXIT_CODE 70 GLUETUN_PF_NETNS_WATCHDOG_EXIT_CODE=256

#------------------------------------------------------------------------------
printf '\n'
if ((FAIL)); then
    printf '%d passed, %d FAILED (%s)\n' "${PASS}" "${FAIL}" "${MODE}"
    printf '  - %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
printf '%d passed, 0 failed (%s)\n' "${PASS}" "${MODE}"
