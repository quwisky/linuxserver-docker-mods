#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# duplicati-discord-notify-mod
#
# NOT `#!/usr/bin/with-contenv bash`, and that is the one deviation from the
# repo's rule for mod scripts. with-contenv REPLACES the environment with the
# container's, discarding whatever the caller set -- which is correct for an s6
# service, where there is no caller, and fatal here: every DUPLICATI__ variable
# this script exists to read is set by Duplicati at exec time and would be wiped
# before the first line ran. Measured in the real image:
#
#     #!/usr/bin/env bash              DUPLICATI__EVENTNAME=AFTER
#     #!/usr/bin/with-contenv bash     DUPLICATI__EVENTNAME=
#
# The container's own DISCORD_ variables still arrive, because Duplicati is
# started by s6 under with-contenv and children inherit its environment. So a
# plain shebang gets both halves; with-contenv gets only one.
#
# `env bash` rather than /bin/bash: the LinuxServer image keeps bash at
# /usr/bin/bash, and an Alpine-based image would keep it elsewhere again.
#
# Dropping with-contenv also drops LinuxServer's UMASK wrapper, which the repo
# README warns about. It costs nothing here: the only files this script creates
# are mktemp's, and mktemp is 0600 whatever the umask. If it ever writes a file
# whose permissions matter, that trade has to be revisited.
#
# Invoked by Duplicati itself, once per operation, via
#
#     --run-script-after=/usr/local/bin/duplicati-discord.sh
#
# set under Settings -> Default options in the web UI. The mod cannot register
# that for you: Duplicati keeps its default options in Duplicati-server.sqlite.
#
# Design constraints, all of them load-bearing:
#
#  * THIS SCRIPT MUST ALWAYS EXIT 0. Duplicati treats a non-zero exit from
#    --run-script-after as the operation having failed, and will say so in its
#    own log and in every other notification you have configured. A Discord
#    webhook being down must never turn a successful backup into a failed one.
#    Hence no `set -e`, no `set -o pipefail`, and an EXIT trap that ends in
#    `exit 0` regardless of what got us there.
#
#  * It runs as whoever Duplicati runs as -- not under s6, not under
#    s6-setuidgid. There is no `abc` to drop to and nothing here needs one: the
#    script reads two files and makes one HTTPS request.
#
#  * --run-script-timeout defaults to 60 seconds, after which Duplicati kills
#    this process. DISCORD_TIMEOUT (20s) plus one bounded 429 retry stays well
#    inside that.
#
# Sourcing it with DISCORD_LIB_ONLY=1 defines everything and runs nothing, which
# is how test/run_tests.sh gets at the pure functions.
#===============================================================================

MOD="discord-notify"
P="[mod-${MOD}]"

# Discord's documented limits. Every one of these is enforced before the payload
# is built, because the API answers an over-long embed with a 400 and a body
# nobody reads.
readonly LIMIT_TITLE=256
readonly LIMIT_DESC=4096
readonly LIMIT_FIELD_NAME=256
readonly LIMIT_FIELD_VALUE=1024
readonly LIMIT_FOOTER=2048
readonly LIMIT_FIELDS=25
readonly LIMIT_EMBED=6000
readonly LIMIT_CONTENT=2000

# Duplicati's operation names, used only to catch a typo in
# DISCORD_NOTIFY_OPERATIONS. Not a closed set -- see the warning in configure().
readonly KNOWN_OPERATIONS="Backup Restore Cleanup Compact Test Repair Delete DeleteAllButN List ListChanges ListAffected ListBrokenFiles PurgeBrokenFiles PurgeFiles Vacuum Verify CreateReport SystemInfo"

readonly ELLIPSIS='…'
readonly WEBHOOK_FILE_DEFAULT="/config/discord-webhook.url"
# Where the mod installs itself. Quoted back to the user in the test message,
# because it is the one string they have to paste into Duplicati by hand.
readonly SCRIPT_PATH="/usr/local/bin/duplicati-discord.sh"

# Colours are Discord's decimal integers, not hex.
declare -A COLOUR=(
    [success]=3066993
    [warning]=15844367
    [error]=15158332
    [fatal]=10038562
    [unknown]=9807270
    # Discord blurple. Deliberately none of the result colours: a test is not a
    # backup outcome and must not be mistaken for one at a glance.
    [test]=5793266
)
declare -A EMOJI=(
    [success]='✅'
    [warning]='⚠️'
    [error]='❌'
    [fatal]='💀'
    [unknown]='❔'
    [test]='🔔'
)

#-------------------------------------------------------------------------------
# Mutable state. Initialised here so nothing is ever unset -- there is no
# `set -u` to catch a typo, so the discipline has to be manual.
#-------------------------------------------------------------------------------
declare -A R=()      # scalars lifted out of the Duplicati result file
declare -a FIELDS=() # flat name,value,inline triples; see fields_json()
declare -a SECRETS=()
declare -a TMPFILES=()
declare -A _JSON_CTRL=()
EMBED_CHARS=0
FIELDS_DROPPED=0
DEBUG="false"   # so dbg() is safe before configure() has run
MULTIBYTE=1     # ditto for truncate_text(); configure() probes it properly
HAVE_JQ=0

#-------------------------------------------------------------------------------
# Logging. STDOUT, never stderr -- this is not a style preference.
#
# Duplicati treats ANY output on stderr from a --run-script hook as a problem and
# raises a warning against the operation:
#
#     [Warning-...RunScript-StdErrorNotEmpty]: The script "..." reported error
#     messages: ...
#
# So a webhook being unreachable, or DISCORD_DEBUG being on, would decorate every
# backup with a warning -- which is the same class of harm as failing the backup,
# and this mod's whole promise is that it cannot do that. Duplicati logs stdout
# from the hook instead (its StdOutToLogs option), which is exactly where these
# belong.
#-------------------------------------------------------------------------------
warn() { echo "${P} $*"; }
dbg() {
    [[ ${DEBUG,,} =~ ^(1|true|yes|on)$ ]] && echo "${P} [debug] $*"
    return 0
}

#-------------------------------------------------------------------------------
# Small pure helpers
#-------------------------------------------------------------------------------
trim() {
    local s=$1
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "${s}"
}

is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }

# hbytes <bytes> -> "1.5 GiB". Pure bash: no bc, no numfmt, and no dependency on
# a locale's decimal separator.
hbytes() {
    local b=$1
    is_uint "${b}" || return 1
    if ((b < 1024)); then
        printf '%d B' "${b}"
        return 0
    fi
    local -a u=(KiB MiB GiB TiB PiB)
    local i=0 val=${b}
    # Step up while a whole unit remains, then carry one decimal by working in
    # tenths -- integer arithmetic is all bash has.
    while ((val >= 1048576 && i < ${#u[@]} - 1)); do
        val=$((val / 1024))
        i=$((i + 1))
    done
    local tenths=$(((val * 10 + 512) / 1024))
    printf '%d.%d %s' $((tenths / 10)) $((tenths % 10)) "${u[i]}"
}

# human_duration "00:04:12.3456789" -> "4m 12s"
# Duplicati reports a .NET TimeSpan, which is [d.]hh:mm:ss[.fffffff]. Sub-second
# precision on a backup duration is noise, so it is dropped.
human_duration() {
    local s
    s="$(trim "$1")"
    [[ ${s} =~ ^(([0-9]+)\.)?([0-9]{1,3}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?$ ]] || return 1
    # 10# so "08" is not read as an invalid octal literal.
    local d=$((10#${BASH_REMATCH[2]:-0}))
    local h=$((10#${BASH_REMATCH[3]}))
    local m=$((10#${BASH_REMATCH[4]}))
    local sec=$((10#${BASH_REMATCH[5]}))
    local out=""
    ((d)) && out+="${d}d "
    ((d || h)) && out+="${h}h "
    ((d || h || m)) && out+="${m}m "
    out+="${sec}s"
    printf '%s' "${out}"
}

# sanitise_url <remote-url> -> the destination with every secret removed.
#
# NON-NEGOTIABLE. Duplicati's DUPLICATI__REMOTEURL carries the backend's
# credentials inline: S3 keys, B2 application keys, OAuth ids and ssh passwords
# all arrive as query parameters or as userinfo. A webhook message is a
# permanent record in someone's chat history, so none of that may be displayed.
sanitise_url() {
    local u
    u="$(trim "$1")"
    [[ -z ${u} ]] && return 1
    # Query string and fragment first: that is where every backend option lives,
    # auth-password and s3 secret keys included.
    u="${u%%\?*}"
    u="${u%%#*}"
    local scheme="" rest="${u}"
    if [[ ${u} == *"://"* ]]; then
        scheme="${u%%://*}://"
        rest="${u#*://}"
    fi
    # Only an @ inside the authority is userinfo. One further along is an
    # ordinary path character -- a folder named after an email address, say.
    local authority="${rest%%/*}" path=""
    [[ ${rest} == */* ]] && path="/${rest#*/}"
    [[ ${authority} == *@* ]] && authority="${authority##*@}"
    printf '%s%s%s' "${scheme}" "${authority}" "${path}"
}

# collect_secrets <remote-url> -- fills SECRETS with the literal values that must
# never appear in the payload.
#
# Stripping the URL is not enough on its own: Duplicati's own exception messages
# routinely quote the whole destination back at you, query string and all, and
# those messages go into the embed's description.
collect_secrets() {
    SECRETS=()
    local u
    u="$(trim "$1")"
    [[ -z ${u} ]] && return 0

    local rest="${u#*://}" query=""
    [[ ${u} == *\?* ]] && query="${u#*\?}"

    local authority="${rest%%[/?]*}"
    if [[ ${authority} == *@* ]]; then
        local userinfo="${authority%@*}"
        [[ -n ${userinfo} ]] && SECRETS+=("${userinfo}")
        # The password half on its own too, since a message may quote only that.
        [[ ${userinfo} == *:* ]] && SECRETS+=("${userinfo#*:}")
    fi

    local -a parts=()
    local kv v
    IFS='&' read -ra parts <<<"${query}"
    for kv in "${parts[@]}"; do
        [[ ${kv} == *=* ]] || continue
        v="${kv#*=}"
        # A short value is a flag or a region name, not a key, and masking it
        # would chew ordinary words out of the log lines.
        ((${#v} >= 8)) && SECRETS+=("${v}")
    done
    return 0
}

# scrub_text <text> -- credential removal for text this mod did not build:
# Duplicati's own log lines.
#
# redact() only knows the secrets belonging to THIS job's destination, and that
# is not the whole exposure. A log line routinely quotes some OTHER URL back at
# you -- a second backend named by an inner exception, an ssh target from a
# sibling job -- so the recognisable SHAPES are removed as well: userinfo in
# front of an @, and any query string that looks like key=value.
#
# Deliberately blunt. Over-masking a log line costs a little readability;
# under-masking one writes a live credential into someone's chat history
# permanently.
scrub_text() {
    printf '%s' "$1" | sed -E \
        -e 's#([A-Za-z0-9_.+-]+):[^[:space:]@/]+@([A-Za-z0-9._-]+)#***@\2#g' \
        -e 's#://[^[:space:]@/]+@#://#g' \
        -e 's#\?[A-Za-z0-9_.-]+=[^[:space:]]*#?***#g'
}

redact() {
    local s=$1 secret
    for secret in "${SECRETS[@]}"; do
        [[ -z ${secret} ]] && continue
        s="${s//"${secret}"/***}"
    done
    printf '%s' "${s}"
}

# truncate_text <text> <max> -- cut to <max> units and mark the cut with an
# ellipsis.
#
# Always called BEFORE the text is JSON-encoded. Truncating encoded JSON would
# happily cut a \uXXXX escape in half, and cutting raw bytes can split a UTF-8
# sequence; doing it here, on the decoded string, is the only ordering that is
# safe for both.
truncate_text() {
    local s=$1 max=$2
    ((max <= 0)) && return 0
    ((${#s} <= max)) && {
        printf '%s' "${s}"
        return 0
    }
    s="${s:0:max - 1}"
    # ${#s} and the slice above count characters in a UTF-8 locale and bytes in
    # the C locale. The LSIO base images set LANG=en_US.UTF-8 so the first is
    # normal, but a container that cleared it would slice bytes and could cut a
    # multibyte sequence in half. MULTIBYTE is probed once, from the length of
    # the ellipsis itself; when it is off, walk back over the trailing non-ASCII
    # run so no partial sequence survives. That costs at most one character, and
    # only in a locale where the character was going to be mangled anyway.
    if ((!MULTIBYTE)); then
        local n
        while ((${#s} > 0)); do
            printf -v n '%d' "'${s: -1}"
            ((n < 0)) && n=$((n + 256))
            ((n < 128)) && break
            s="${s:0:${#s} - 1}"
            ((n >= 192)) && break # that was the lead byte; the sequence is gone
        done
    fi
    printf '%s%s' "${s}" "${ELLIPSIS}"
}

# json_escape <string> -- a JSON string body, without the surrounding quotes.
#
# Only ever used on the NO_JQ path. Everywhere jq is available the payload is
# built with --arg, because a backup name or a stack trace will contain quotes,
# newlines and backslashes and string concatenation gets that wrong eventually.
json_escape() {
    local s=$1
    # Backslash first: doing it later would escape the escapes added below.
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\b'/\\b}"
    s="${s//$'\f'/\\f}"
    # The five above are the only control characters with a short escape; the
    # rest have to go out as \u00XX. They are rare enough to be worth testing for
    # before paying for a per-character loop.
    if [[ ${s} == *[[:cntrl:]]* ]]; then
        local out="" i c
        for ((i = 0; i < ${#s}; i++)); do
            c="${s:i:1}"
            out+="${_JSON_CTRL[${c}]:-${c}}"
        done
        s="${out}"
    fi
    printf '%s' "${s}"
}

# The \u00XX table, built once. Bash cannot portably turn a character back into
# a code point in a UTF-8 locale, so the mapping is materialised the other way
# round: from the code point to the character.
_json_ctrl_init() {
    local i ch
    for ((i = 1; i < 32; i++)); do
        # '%b' as a literal format keeps the octal escape in the ARGUMENT, which
        # is what stops this from being a variable-in-format bug.
        printf -v ch '%b' "\\0$(printf '%o' "${i}")"
        printf -v "_JSON_CTRL[${ch}]" '\\u%04x' "${i}"
    done
}
_json_ctrl_init

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
resolve_webhook() {
    local v=""
    if [[ -n ${DISCORD_WEBHOOK_URL:-} ]]; then
        v="${DISCORD_WEBHOOK_URL}"
    elif [[ -n ${DISCORD_WEBHOOK_URL_FILE:-} ]]; then
        # Docker secrets and OpenBao templates both land as a file. Unreadable is
        # worth a word: it is almost always a permissions mistake, and silence
        # would leave someone staring at a container that never notifies.
        if [[ -r ${DISCORD_WEBHOOK_URL_FILE} ]]; then
            v="$(<"${DISCORD_WEBHOOK_URL_FILE}")"
        else
            warn "DISCORD_WEBHOOK_URL_FILE=${DISCORD_WEBHOOK_URL_FILE} is not readable"
        fi
    elif [[ -r ${WEBHOOK_FILE} ]]; then
        v="$(<"${WEBHOOK_FILE}")"
    fi
    # $(<file) already drops trailing newlines; the trim also takes the CR that
    # a file written on Windows carries, which would otherwise end up in the URL.
    trim "${v//$'\r'/}"
}

configure() {
    NOTIFY_ON="${DISCORD_NOTIFY_ON:-all}"
    NOTIFY_OPERATIONS="${DISCORD_NOTIFY_OPERATIONS:-Backup}"
    USERNAME="${DISCORD_USERNAME:-Duplicati}"
    AVATAR_URL="$(trim "${DISCORD_AVATAR_URL:-}")"
    MENTION="$(trim "${DISCORD_MENTION_ON_ERROR:-}")"
    LOG_LINES="${DISCORD_LOG_LINES:-10}"
    TIMEOUT="${DISCORD_TIMEOUT:-20}"
    DEBUG="${DISCORD_DEBUG:-false}"
    # Not an environment knob: the tests reach it by assigning WEBHOOK_FILE
    # directly after configure(), which keeps a second, near-identical
    # DISCORD_WEBHOOK_*_FILE name out of the documented surface.
    WEBHOOK_FILE="${WEBHOOK_FILE_DEFAULT}"

    # Both filters used to fail silently on a typo, in opposite and equally
    # unhelpful directions: an unrecognised DISCORD_NOTIFY_ON fell through to
    # "all", so someone asking for errors only got a message after every backup,
    # and an unrecognised operation name matched nothing, so the mod went quiet
    # for good and simply looked broken. Say so, in both cases, and carry on.
    case "${NOTIFY_ON,,}" in
        all | warning | error) ;;
        *)
            warn "DISCORD_NOTIFY_ON='${NOTIFY_ON}' is not one of all|warning|error; using 'all'"
            NOTIFY_ON="all"
            ;;
    esac

    local -a wanted=()
    local want
    IFS=',' read -ra wanted <<<"${NOTIFY_OPERATIONS}"
    for want in "${wanted[@]}"; do
        want="$(trim "${want}")"
        [[ -z ${want} || ${want} == "*" ]] && continue
        # Warned about, not rejected: Duplicati has added operations before and
        # will again, and refusing an unknown name would break on the upgrade
        # rather than on the typo.
        if [[ " ${KNOWN_OPERATIONS,,} " != *" ${want,,} "* ]]; then
            warn "DISCORD_NOTIFY_OPERATIONS lists '${want}', which is not a Duplicati operation name."
            warn "  -> known names are: ${KNOWN_OPERATIONS}"
            warn "  -> nothing will be sent for it; use '*' to allow every operation."
        fi
    done

    is_uint "${LOG_LINES}" || LOG_LINES=10
    ((LOG_LINES > 50)) && LOG_LINES=50
    is_uint "${TIMEOUT}" || TIMEOUT=20
    ((TIMEOUT < 1)) && TIMEOUT=20

    HOST="$(trim "${DISCORD_HOSTNAME:-}")"
    if [[ -z ${HOST} ]]; then
        # $HOSTNAME is a bash variable and needs no binary; `hostname` lives in a
        # package the image is not obliged to carry.
        HOST="${HOSTNAME:-}"
        [[ -z ${HOST} && -r /etc/hostname ]] && read -r HOST </etc/hostname
        [[ -z ${HOST} ]] && HOST="$(hostname 2>/dev/null)"
        [[ -z ${HOST} ]] && HOST="unknown"
    fi

    # Gated on NO_JQ as well as on jq's absence, so the test suite can force the
    # degraded path on a machine that has jq -- which is every CI runner.
    if [[ ${NO_JQ:-0} == 1 ]] || ! command -v jq >/dev/null 2>&1; then
        HAVE_JQ=0
    else
        HAVE_JQ=1
    fi

    # One probe for the whole run: in a multibyte locale the ellipsis is one
    # character, in the C locale it is three bytes. truncate_text needs to know.
    if ((${#ELLIPSIS} == 1)); then MULTIBYTE=1; else MULTIBYTE=0; fi

    WEBHOOK="$(resolve_webhook)"

    # What Duplicati exports to --run-script-after. Every job option arrives as
    # DUPLICATI__<option> with dashes turned into underscores, which is why the
    # backup's name is DUPLICATI__backup_name and not something tidier.
    EVENTNAME="$(trim "${DUPLICATI__EVENTNAME:-}")"
    OPERATION="$(trim "${DUPLICATI__OPERATIONNAME:-}")"
    RESULT="$(trim "${DUPLICATI__PARSED_RESULT:-}")"
    RESULTFILE="${DUPLICATI__RESULTFILE:-}"
    REMOTEURL="$(trim "${DUPLICATI__REMOTEURL:-}")"
    LOCALPATH="$(trim "${DUPLICATI__LOCALPATH:-}")"
    BACKUP_NAME="$(trim "${DUPLICATI__backup_name:-}")"
    [[ -z ${BACKUP_NAME} ]] && BACKUP_NAME="Duplicati"
    [[ -z ${RESULT} ]] && RESULT="Unknown"
}

#-------------------------------------------------------------------------------
# Filters
#-------------------------------------------------------------------------------
# operation_allowed <operation> -- DISCORD_NOTIFY_OPERATIONS is a comma-separated
# allowlist, or `*` for everything.
operation_allowed() {
    local op=${1,,} want
    local -a wanted=()
    IFS=',' read -ra wanted <<<"${NOTIFY_OPERATIONS}"
    for want in "${wanted[@]}"; do
        want="$(trim "${want}")"
        [[ -z ${want} ]] && continue
        [[ ${want} == "*" ]] && return 0
        [[ ${want,,} == "${op}" ]] && return 0
    done
    return 1
}

# severity_allowed <parsed-result>
#
# Unknown counts as "not a problem": it is what Duplicati reports for operations
# that produce no parsed result at all, and treating it as an error would page
# someone every time they ran a Test.
severity_allowed() {
    local r=${1,,}
    case "${NOTIFY_ON,,}" in
        error) [[ ${r} == "error" || ${r} == "fatal" ]] ;;
        warning) [[ ${r} == "warning" || ${r} == "error" || ${r} == "fatal" ]] ;;
        *) return 0 ;;
    esac
}

#-------------------------------------------------------------------------------
# Reading Duplicati's result file
#-------------------------------------------------------------------------------
# The keys worth displaying. Order is irrelevant; the field layout is decided
# further down.
readonly RESULT_KEYS=(
    MainOperation Duration ParsedResult
    ExaminedFiles AddedFiles ModifiedFiles DeletedFiles SizeOfExaminedFiles
    BytesUploaded BytesDownloaded FilesUploaded
    TotalQuotaSpace FreeQuotaSpace
    ErrorsActualLength WarningsActualLength
)

load_result() {
    R=()
    [[ -n ${RESULTFILE} && -r ${RESULTFILE} ]] || {
        dbg "no readable result file; the embed will carry no statistics"
        return 1
    }

    if ((HAVE_JQ)); then
        _load_result_jq && return 0
        dbg "the result file is not JSON; falling back to a line scan"
    fi
    _load_result_scan
}

_load_result_jq() {
    local keys_json out key val
    keys_json="$(printf '%s\n' "${RESULT_KEYS[@]}" | jq -Rc '[., inputs]' 2>/dev/null)" || return 1

    # RECURSIVE DESCENT, not a fixed path, and deliberately so: these fields have
    # moved between the top level, .BackendStatistics and .MainOperationResult
    # across Duplicati 2.0.x and 2.2.x. A fixed path yields null on exactly the
    # versions where it moved, and null is indistinguishable from "the backup
    # uploaded nothing" -- so the mod would silently start omitting rows after an
    # upgrade. `first` takes the shallowest match, objects and arrays are skipped
    # so a container named like a scalar cannot win.
    out="$(jq -r --argjson keys "${keys_json}" '
        $keys[] as $k
        | ([ .. | objects | select(has($k)) | .[$k]
             | select((type == "object" or type == "array") | not) ] | first) as $v
        | select($v != null)
        | "\($k)\t\($v)"
    ' "${RESULTFILE}" 2>/dev/null)" || return 1
    [[ -z ${out} ]] && return 1

    while IFS=$'\t' read -r key val; do
        [[ -n ${key} ]] && R["${key}"]="${val}"
    done <<<"${out}"
    return 0
}

# The no-jq path, and also the path for the plain-text result format someone gets
# when they skip --run-script-result-output-format=Json. A dumb scan for
# `"Key": value` or `Key: value` anywhere in the file, which is the same
# nesting-agnostic rule as above, minus any idea of types.
_load_result_scan() {
    local key line val found=0
    for key in "${RESULT_KEYS[@]}"; do
        line="$(grep -m1 -E "^[[:space:]]*\"?${key}\"?[[:space:]]*:" "${RESULTFILE}" 2>/dev/null)" || continue
        val="${line#*:}"
        val="$(trim "${val}")"
        val="${val%,}"
        val="$(trim "${val}")"
        val="${val#\"}"
        val="${val%\"}"
        [[ -z ${val} || ${val} == "null" || ${val} == "{" || ${val} == "[" ]] && continue
        R["${key}"]="${val}"
        found=1
    done
    ((found))
}

# result_lines <Errors|Warnings> -- up to LOG_LINES entries, one per line.
result_lines() {
    local key=$1
    [[ -n ${RESULTFILE} && -r ${RESULTFILE} ]] || return 1
    if ((HAVE_JQ)); then
        jq -r --arg k "${key}" --argjson n "${LOG_LINES}" '
            ([ .. | objects | select(has($k)) | .[$k] | select(type == "array") ] | first) // []
            | .[0:$n] | .[] | tostring
            | gsub("[\r\n]+"; " ")
        ' "${RESULTFILE}" 2>/dev/null
        return 0
    fi
    # No jq: pull the quoted strings out of the array literal. Good enough to
    # show someone what broke, and this path is degraded by definition.
    sed -n "/\"${key}\"[[:space:]]*:[[:space:]]*\[/,/\]/p" "${RESULTFILE}" 2>/dev/null |
        grep -oE '"[^"]{4,}"' | grep -vE "^\"${key}\"$" | sed 's/^"//; s/"$//' | head -n "${LOG_LINES}"
}

#-------------------------------------------------------------------------------
# Assembling the embed
#-------------------------------------------------------------------------------
result_key() {
    local r=${RESULT,,}
    case "${r}" in
        success | warning | error | fatal) printf '%s' "${r}" ;;
        *) printf 'unknown' ;;
    esac
}

# add_field <name> <value> [inline]
#
# An absent value drops the whole field. Discord has no way to render "not
# applicable" that does not look like a bug, and a row saying N/A is worse than
# no row.
add_field() {
    local name=$1 value=$2 inline=${3:-true}
    [[ -z ${value} ]] && return 0
    # Unreachable with today's fixed set of at most 15 fields, and kept
    # deliberately: it is the only thing standing between a future field and a
    # 400 from Discord. Same for the total below, which the description clamp in
    # build_description() is what actually enforces today.
    if ((${#FIELDS[@]} / 3 >= LIMIT_FIELDS)); then
        FIELDS_DROPPED=$((FIELDS_DROPPED + 1))
        return 0
    fi
    name="$(truncate_text "${name}" "${LIMIT_FIELD_NAME}")"
    value="$(truncate_text "${value}" "${LIMIT_FIELD_VALUE}")"
    # Discord's 6000 is the sum of title, description, footer and every field
    # name and value in the embed. Overshooting it is a 400 for the whole
    # message, so a field that will not fit is dropped rather than sent.
    local cost=$((${#name} + ${#value}))
    if ((EMBED_CHARS + cost > LIMIT_EMBED)); then
        FIELDS_DROPPED=$((FIELDS_DROPPED + 1))
        return 0
    fi
    EMBED_CHARS=$((EMBED_CHARS + cost))
    FIELDS+=("${name}" "${value}" "${inline}")
    return 0
}

fields_json() {
    ((${#FIELDS[@]} == 0)) && {
        printf '[]'
        return 0
    }
    # One jq invocation for the whole array: the triples arrive as positional
    # arguments, so no shell quoting ever touches the JSON.
    jq -nc --args '
        [ range(0; ($ARGS.positional | length); 3)
          | { name:   $ARGS.positional[.],
              value:  $ARGS.positional[. + 1],
              inline: ($ARGS.positional[. + 2] == "true") } ]
    ' -- "${FIELDS[@]}"
}

# count_field <label> <n> <show-zero> -- see the note at its call site.
count_field() {
    local label=$1 n=$2 show_zero=$3
    is_uint "${n}" || return 0
    ((n > 0 || show_zero)) && add_field "${label}" "${n}"
    return 0
}

collect_fields() {
    local v used total

    add_field "Operation" "${OPERATION:-${R[MainOperation]:-}}"

    if v="$(human_duration "${R[Duration]:-}")"; then
        add_field "Duration" "${v}"
    fi

    add_field "Files examined" "${R[ExaminedFiles]:-}"
    add_field "Added" "${R[AddedFiles]:-}"
    add_field "Modified" "${R[ModifiedFiles]:-}"
    add_field "Deleted" "${R[DeletedFiles]:-}"

    if v="$(hbytes "${R[SizeOfExaminedFiles]:-}")"; then
        add_field "Size examined" "${v}"
    fi
    if v="$(hbytes "${R[BytesUploaded]:-}")"; then
        add_field "Uploaded" "${v}"
    fi
    if v="$(hbytes "${R[BytesDownloaded]:-}")"; then
        add_field "Downloaded" "${v}"
    fi
    add_field "Files uploaded" "${R[FilesUploaded]:-}"

    # Quota is only meaningful as used-of-total, and only some backends report
    # it at all -- so it appears only when both halves are present.
    total="${R[TotalQuotaSpace]:-}"
    if is_uint "${total}" && is_uint "${R[FreeQuotaSpace]:-}" && ((total > 0)); then
        used=$((total - R[FreeQuotaSpace]))
        ((used < 0)) && used=0
        add_field "Quota used" "$(hbytes "${used}") of $(hbytes "${total}") ($((used * 100 / total))%)"
    fi

    # Counts are shown when they are non-zero, and on a non-success result they
    # are shown even at zero -- "3 errors, 0 warnings" is information, whereas
    # "0 errors" under a green tick is just a row to scroll past.
    local show_zero=0
    [[ $(result_key) != "success" ]] && show_zero=1
    count_field "Errors" "${R[ErrorsActualLength]:-}" "${show_zero}"
    count_field "Warnings" "${R[WarningsActualLength]:-}" "${show_zero}"

    # Not inline: a destination or a source list is long, and a third of a row
    # would truncate it into uselessness.
    if v="$(sanitise_url "${REMOTEURL}")"; then
        add_field "Destination" "${v}" false
    fi
    if [[ -n ${LOCALPATH} ]]; then
        # Duplicati joins source paths with a colon, the same separator PATH uses.
        local -a srcs=()
        IFS=':' read -ra srcs <<<"${LOCALPATH}"
        local joined="" s
        for s in "${srcs[@]}"; do
            s="$(trim "${s}")"
            [[ -z ${s} ]] && continue
            joined+="${joined:+, }${s}"
        done
        add_field "Source" "${joined}" false
    fi
    return 0
}

# build_description -- the fenced log block, or nothing on a clean run.
build_description() {
    [[ $(result_key) == "success" ]] && return 0
    local room=$((LIMIT_EMBED - EMBED_CHARS))
    ((room > LIMIT_DESC)) && room=${LIMIT_DESC}
    # The fence itself costs characters; below this there is no room for content
    # worth showing.
    ((room < 32)) && return 0

    local body="" kind line
    for kind in Errors Warnings; do
        local block=""
        while IFS= read -r line; do
            line="$(trim "${line}")"
            [[ -z ${line} ]] && continue
            block+="  ${line}"$'\n'
        done < <(result_lines "${kind}")
        [[ -n ${block} ]] && body+="${kind}:"$'\n'"${block}"
    done
    [[ -z ${body} ]] && return 0

    # Both passes, in this order: the exact known secrets first, then the
    # shapes. Neither subsumes the other.
    body="$(scrub_text "$(redact "${body}")")"
    # 9 = the two fence lines and their newlines.
    body="$(truncate_text "${body}" $((room - 9)))"
    # shellcheck disable=SC2016  # those backticks are Discord's code fence, not a subshell
    printf '```\n%s\n```' "${body}"
}

build_title() {
    local k
    k="$(result_key)"
    truncate_text "${EMOJI[${k}]} ${BACKUP_NAME} — ${RESULT}" "${LIMIT_TITLE}"
}

build_content() {
    # A mention belongs on the message, not in the embed: Discord only notifies
    # for mentions in `content`. Errors only -- a ping for a warning trains
    # people to ignore the ping.
    local k
    k="$(result_key)"
    [[ -n ${MENTION} && (${k} == "error" || ${k} == "fatal") ]] || return 0
    truncate_text "${MENTION}" "${LIMIT_CONTENT}"
}

build_payload() {
    local title footer desc content fields colour timestamp
    # Reset the accumulators: they are globals so add_field() can reach them,
    # which makes a second call in one process double-count without this.
    FIELDS=()
    EMBED_CHARS=0
    FIELDS_DROPPED=0
    title="$(build_title)"
    EMBED_CHARS=$((EMBED_CHARS + ${#title}))
    footer="$(truncate_text "${HOST} • Duplicati" "${LIMIT_FOOTER}")"
    EMBED_CHARS=$((EMBED_CHARS + ${#footer}))

    collect_fields
    desc="$(build_description)"
    content="$(build_content)"
    colour="${COLOUR[$(result_key)]}"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    ((FIELDS_DROPPED)) && dbg "${FIELDS_DROPPED} field(s) dropped to stay inside Discord's limits"

    if ((!HAVE_JQ)); then
        build_payload_fallback "${title}" "${content}"
        return 0
    fi

    fields="$(fields_json)"
    # Every string goes in through --arg, never through string interpolation:
    # backup names and stack traces contain quotes, newlines and backslashes,
    # and hand-built JSON gets that wrong on the day it matters most.
    jq -nc \
        --arg username "${USERNAME}" \
        --arg avatar "${AVATAR_URL}" \
        --arg content "${content}" \
        --arg title "${title}" \
        --arg desc "${desc}" \
        --arg footer "${footer}" \
        --arg ts "${timestamp}" \
        --argjson colour "${colour}" \
        --argjson fields "${fields}" '
        {
            username: $username,
            embeds: [
                ({ title: $title, color: $colour, fields: $fields,
                   footer: { text: $footer }, timestamp: $ts }
                 + (if $desc == "" then {} else { description: $desc } end))
            ]
        }
        + (if $avatar  == "" then {} else { avatar_url: $avatar  } end)
        + (if $content == "" then {} else { content:    $content } end)
    '
}

# No jq: one flat {"content": "..."} message. No embed, no colour, no fields --
# a deliberately poorer notification rather than a clever one assembled by string
# concatenation, which is how invalid JSON and leaked quotes happen.
build_payload_fallback() {
    local title=$1 content=$2
    local line="${title}" i v

    # The same facts the embed would carry, on one line, from the same FIELDS
    # array -- so the two paths cannot drift apart.
    for ((i = 0; i + 1 < ${#FIELDS[@]}; i += 3)); do
        v="$(redact "${FIELDS[i + 1]}")"
        line+=$'\n'"${FIELDS[i]}: ${v}"
    done

    [[ -n ${content} ]] && line="${content} ${line}"
    line="$(truncate_text "${line}" "${LIMIT_CONTENT}")"

    local out='{"username":"'
    out+="$(json_escape "${USERNAME}")"
    out+='","content":"'
    out+="$(json_escape "${line}")"
    out+='"}'
    printf '%s' "${out}"
}

# build_test_payload -- what DISCORD_TEST_ON_START sends at container start.
#
# Deliberately not build_payload() with synthetic data: there is no operation
# and no result file, and rendering "Files examined: 0" against a backup that
# never ran would be worse than saying nothing. It reuses the same truncation,
# encoding and delivery, so a test message that arrives proves the real path.
build_test_payload() {
    local title desc footer timestamp
    title="$(truncate_text "${EMOJI[test]} ${BACKUP_NAME} — Test notification" "${LIMIT_TITLE}")"
    footer="$(truncate_text "${HOST} • Duplicati" "${LIMIT_FOOTER}")"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    desc="$(truncate_text "$(
        printf '%s\n\n' "The webhook is reachable and this container can post to it."
        printf '%s\n' "Duplicati still has to be told to run the script. In the web UI, under"
        printf '%s\n\n' "**Settings → Default options**:"
        printf '%s\n' '```'
        printf '%s\n' "--run-script-after=${SCRIPT_PATH}"
        printf '%s\n' "--run-script-result-output-format=Json"
        printf '%s\n\n' '```'
        printf '%s' "Set DISCORD_TEST_ON_START=false to stop sending this."
    )" "${LIMIT_DESC}")"

    if ((!HAVE_JQ)); then
        # Degraded, but not less useful: the two things a reader has to act on
        # are the option to paste and the variable to unset.
        local line="${title}"
        line+=$'\n'"The webhook works. In Duplicati's web UI, under Settings -> Default options, add:"
        line+=$'\n'"  --run-script-after=${SCRIPT_PATH}"
        line+=$'\n'"  --run-script-result-output-format=Json"
        line+=$'\n'"Set DISCORD_TEST_ON_START=false to stop sending this."
        line="$(truncate_text "${line}" "${LIMIT_CONTENT}")"
        printf '{"username":"%s","content":"%s"}' \
            "$(json_escape "${USERNAME}")" "$(json_escape "${line}")"
        return 0
    fi

    jq -nc \
        --arg username "${USERNAME}" \
        --arg avatar "${AVATAR_URL}" \
        --arg title "${title}" \
        --arg desc "${desc}" \
        --arg footer "${footer}" \
        --arg ts "${timestamp}" \
        --argjson colour "${COLOUR[test]}" '
        {
            username: $username,
            embeds: [{
                title: $title, color: $colour, description: $desc,
                footer: { text: $footer }, timestamp: $ts
            }]
        }
        + (if $avatar == "" then {} else { avatar_url: $avatar } end)
    '
}

#-------------------------------------------------------------------------------
# Delivery
#-------------------------------------------------------------------------------
mktemp_tracked() {
    local f
    f="$(mktemp 2>/dev/null)" || return 1
    TMPFILES+=("${f}")
    printf '%s' "${f}"
}

# retry_after <file> -- Discord's 429 body carries retry_after in seconds, as a
# float since API v8. Rounded up, and clamped: a global rate limit can report
# minutes, and Duplicati kills this script at --run-script-timeout.
retry_after() {
    local file=$1 v=""
    if ((HAVE_JQ)); then
        v="$(jq -r '.retry_after // empty' "${file}" 2>/dev/null)"
    else
        v="$(grep -oE '"retry_after"[[:space:]]*:[[:space:]]*[0-9.]+' "${file}" 2>/dev/null | grep -oE '[0-9.]+$')"
    fi
    [[ ${v} =~ ^([0-9]+)(\.[0-9]+)?$ ]] || {
        printf '1'
        return 0
    }
    local secs=$((10#${BASH_REMATCH[1]}))
    [[ -n ${BASH_REMATCH[2]} && ${BASH_REMATCH[2]} != .0* ]] && secs=$((secs + 1))
    ((secs < 1)) && secs=1
    ((secs > 10)) && secs=10
    printf '%s' "${secs}"
}

deliver() {
    local payload=$1 attempt=0 body cerr code rc wait
    body="$(mktemp_tracked)" || {
        warn "could not create a temporary file; not sending"
        return 1
    }
    # curl -sS reports its own failures on stderr, and Duplicati raises a warning
    # against the backup for anything that appears there. Captured and re-emitted
    # on stdout below, so the diagnosis survives without costing the operation a
    # warning it did not earn.
    cerr="$(mktemp_tracked)" || cerr=/dev/null

    while :; do
        # Two things are kept out of the process table, for different reasons.
        # The payload goes in on stdin because a multi-kilobyte embed would
        # otherwise risk ARG_MAX. The URL goes in through --config because it
        # IS the secret: anything in argv is world-readable via /proc/<pid>/cmdline
        # to every process running as this uid, and the token in a webhook URL is
        # the whole credential. Process substitution keeps it off disk as well.
        code="$(printf '%s' "${payload}" | curl -sS -m "${TIMEOUT}" \
            -H 'Content-Type: application/json' \
            -o "${body}" -w '%{http_code}' \
            -X POST --data-binary @- \
            --config <(printf 'url = "%s"\n' "${WEBHOOK}") 2>"${cerr}")"
        rc=$?

        if ((rc != 0)); then
            warn "**** curl failed (exit ${rc}); the notification was not sent ****"
            warn "  -> $(tr '\n' ' ' <"${cerr}" 2>/dev/null)"
            return 1
        fi

        if [[ ${code} == 429 && ${attempt} -eq 0 ]]; then
            wait="$(retry_after "${body}")"
            dbg "rate limited by Discord; retrying once in ${wait}s"
            sleep "${wait}"
            attempt=1
            continue
        fi

        case "${code}" in
            2*)
                dbg "delivered (HTTP ${code})"
                return 0
                ;;
            401 | 403 | 404)
                warn "**** Discord rejected the webhook (HTTP ${code}) ****"
                warn "  -> the webhook URL is wrong, or the webhook was deleted in Discord."
                warn "  -> it must be the full https://discord.com/api/webhooks/<id>/<token> URL."
                ;;
            *)
                warn "**** Discord returned HTTP ${code}; the notification was not sent ****"
                ;;
        esac
        # Truncated on purpose: the response can be long, and this goes into
        # Duplicati's log on every failed operation.
        warn "  -> $(head -c 400 "${body}" 2>/dev/null | tr '\n' ' ')"
        return 1
    done
}

#-------------------------------------------------------------------------------
cleanup() {
    local f
    for f in "${TMPFILES[@]}"; do
        [[ -n ${f} ]] && rm -f "${f}"
    done
    # The whole point. Whatever happened above -- a failed curl, a missing result
    # file, a bug in here -- Duplicati must see a zero exit, or it records the
    # backup itself as failed.
    exit 0
}

main() {
    trap cleanup EXIT

    configure

    # --test is the startup check, invoked by the second init oneshot when
    # DISCORD_TEST_ON_START is truthy. It bypasses the operation and severity
    # filters on purpose: someone asking "does my webhook work" wants an answer,
    # not silence because they also set DISCORD_NOTIFY_ON=error.
    if [[ ${1-} == "--test" ]]; then
        if [[ -z ${WEBHOOK} ]]; then
            # Loud here, unlike the per-backup path. This runs once, at start,
            # into the container log -- exactly where someone who just turned
            # the test on will look, and the only reason it would be silent is
            # the thing they need to fix.
            warn "**** DISCORD_TEST_ON_START is set but no webhook is configured ****"
            warn "  -> set DISCORD_WEBHOOK_URL, or DISCORD_WEBHOOK_URL_FILE, or write the URL"
            warn "     to ${WEBHOOK_FILE}"
            return 0
        fi
        local test_payload
        test_payload="$(build_test_payload)"
        dbg "test payload: ${test_payload}"
        if deliver "${test_payload}"; then
            echo "${P} **** test notification sent ****"
        fi
        return 0
    fi

    # BEFORE and AFTER both fire when --run-script-before is set to this same
    # script; only the AFTER pass has a result to report.
    [[ ${EVENTNAME^^} == "AFTER" ]] || {
        dbg "event is '${EVENTNAME}', not AFTER; nothing to do"
        return 0
    }

    if [[ -z ${WEBHOOK} ]]; then
        # Silent by design: the mod is installed on plenty of containers before
        # anyone gets round to creating the webhook, and a warning on every
        # backup would be the only thing anyone ever saw in the log.
        dbg "no webhook configured; nothing to send"
        return 0
    fi

    if ! operation_allowed "${OPERATION}"; then
        dbg "operation '${OPERATION}' is not in DISCORD_NOTIFY_OPERATIONS='${NOTIFY_OPERATIONS}'"
        return 0
    fi
    if ! severity_allowed "${RESULT}"; then
        dbg "result '${RESULT}' is below DISCORD_NOTIFY_ON='${NOTIFY_ON}'"
        return 0
    fi

    collect_secrets "${REMOTEURL}"
    load_result

    local payload
    payload="$(build_payload)"
    if [[ -z ${payload} ]]; then
        warn "**** could not build a payload; nothing sent ****"
        return 0
    fi
    dbg "payload: ${payload}"

    deliver "${payload}"
    return 0
}

[[ ${DISCORD_LIB_ONLY:-0} == 1 ]] || main "$@"
