#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for duplicati-discord.sh. No network, no Docker, no Duplicati and
# no Discord: the script is sourced with DISCORD_LIB_ONLY=1, which defines
# everything and runs nothing, and `curl` is shadowed by a shell function that
# writes the payload to a file instead of sending it.
#
#   bash test/run_tests.sh              # with jq
#   NO_JQ=1 bash test/run_tests.sh      # the pure-bash fallback payload
#
# NO_JQ is a real gate inside the mod, not a PATH trick, so the suite itself can
# still use the host's jq to VALIDATE what the degraded path produced -- which
# is the only way to assert "the fallback emits valid JSON" at all.
#
# Needs bash 4+ (declare -A, ${VAR,,}, read -ra). macOS ships bash 3.2, so:
#
#   docker run --rm -v "$PWD:/mnt" -w /mnt bash:5 \
#     sh -c 'apk add -q jq && bash mods/duplicati/discord-notify-mod/test/run_tests.sh'

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="${HERE}/../root/usr/local/bin/duplicati-discord.sh"
FIX="${HERE}/fixtures"

if [[ ${NO_JQ:-0} == 1 ]]; then MODE="no-jq"; else MODE="with-jq"; fi

# The suite's own jq, deliberately independent of the mod's NO_JQ gate.
have_jq() { command -v jq >/dev/null 2>&1; }
if ! have_jq; then
    echo "NOTE: jq is not installed; the JSON-shape assertions will be skipped." >&2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../root/usr/local/bin/duplicati-discord.sh
DISCORD_LIB_ONLY=1 source "${MOD}"

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
yes_() { if "${@:2}"; then ok "$1"; else no "$1" "true" "false"; fi; }
not() { if "${@:2}"; then no "$1" "false" "true"; else ok "$1"; fi; }
has() { if [[ $2 == *"$3"* ]]; then ok "$1"; else no "$1" "a string containing '$3'" "$2"; fi; }
hasnt() { if [[ $2 == *"$3"* ]]; then no "$1" "no '$3' anywhere" "$2"; else ok "$1"; fi; }
section() { printf '\n== %s (%s) ==\n' "$1" "${MODE}"; }

#------------------------------------------------------------------------------
section "hbytes(): human-readable sizes without bc or numfmt"
#------------------------------------------------------------------------------
eq 'zero'          '0 B'       "$(hbytes 0)"
eq 'below 1 KiB'   '1023 B'    "$(hbytes 1023)"
eq 'exactly 1 KiB' '1.0 KiB'   "$(hbytes 1024)"
eq 'one decimal'   '1.5 KiB'   "$(hbytes 1536)"
eq '1 MiB'         '1.0 MiB'   "$(hbytes 1048576)"
eq '1 GiB'         '1.0 GiB'   "$(hbytes 1073741824)"
eq '1 TiB'         '1.0 TiB'   "$(hbytes 1099511627776)"
eq 'a real backup' '919.8 GiB' "$(hbytes 987654321098)"
eq 'just under a MiB stays in KiB' '1023.4 KiB' "$(hbytes 1048000)"
# An absent or non-numeric value must FAIL rather than print something, so the
# caller omits the field instead of rendering a placeholder.
not 'empty is not a size'    hbytes ''
not 'a word is not a size'   hbytes 'lots'
not 'negative is not a size' hbytes '-1'

#------------------------------------------------------------------------------
section "human_duration(): a .NET TimeSpan is not a number of seconds"
#------------------------------------------------------------------------------
eq 'the documented example' '4m 12s'      "$(human_duration '00:04:12.3456789')"
eq 'seconds only'           '9s'          "$(human_duration '00:00:09.4410000')"
eq 'no fractional part'     '47s'         "$(human_duration '00:00:47')"
eq 'hours appear'           '1h 2m 3s'    "$(human_duration '01:02:03')"
eq 'days appear'            '2d 3h 4m 5s' "$(human_duration '2.03:04:05')"
eq 'leading zeros are not octal' '8m 9s'  "$(human_duration '00:08:09')"
eq 'an hour keeps its minutes' '3h 0m 0s' "$(human_duration '03:00:00')"
not 'empty is not a duration'    human_duration ''
not 'a number is not a TimeSpan' human_duration '252'
not 'nonsense is rejected'       human_duration 'a while'

#------------------------------------------------------------------------------
section "sanitise_url(): a webhook message must never carry a backend key"
#------------------------------------------------------------------------------
# The single most important thing in this file. Everything else is cosmetic.
eq 's3 query string is dropped' 's3://acme-offsite-backups/nas' \
    "$(sanitise_url 's3://acme-offsite-backups/nas?s3-server-name=s3.eu-central-1.amazonaws.com&auth-username=AKIAIOSFODNN7EXAMPLE&auth-password=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY')"
eq 'ssh userinfo is dropped' 'ssh://nas.example.internal:22/volume1/duplicati' \
    "$(sanitise_url 'ssh://backupsvc:hunter2SuperSecretPassphrase@nas.example.internal:22/volume1/duplicati')"
eq 'ftp username alone is dropped' 'ftp://ftp.example.com/backup' \
    "$(sanitise_url 'ftp://someuser@ftp.example.com/backup')"
eq 'both at once' 'b2://my-bucket/duplicati' \
    "$(sanitise_url 'b2://keyid:appkeysecret@my-bucket/duplicati?auth-password=another-secret')"
eq 'oauth authid is dropped' 'googledrive://Backups/nas' \
    "$(sanitise_url 'googledrive://Backups/nas?authid=abcdef0123456789')"
eq 'a fragment goes too' 'webdav://nas.local/backup' \
    "$(sanitise_url 'webdav://nas.local/backup#token=nope')"
# The things that must SURVIVE, or the field stops being useful.
eq 'a local path is left alone'  'file:///backups/duplicati' "$(sanitise_url 'file:///backups/duplicati')"
eq 'the port survives'           'ssh://nas.local:2222/vol'  "$(sanitise_url 'ssh://nas.local:2222/vol')"
eq 'a scheme-less path survives' '/mnt/backups'              "$(sanitise_url '/mnt/backups')"
# An @ in the PATH is an ordinary character -- a folder named for an email
# address -- and trimming at the last @ in the whole string would eat the host.
eq 'an @ in the path is not userinfo' 'sftp://nas.local/home/ana@example.com/backup' \
    "$(sanitise_url 'sftp://nas.local/home/ana@example.com/backup')"
eq 'surrounding whitespace is trimmed' 's3://bucket/path' "$(sanitise_url '  s3://bucket/path  ')"
not 'empty yields nothing at all' sanitise_url ''

#------------------------------------------------------------------------------
section "collect_secrets()/redact(): the URL is quoted back inside log lines"
#------------------------------------------------------------------------------
collect_secrets 's3://bucket/p?auth-username=AKIAIOSFODNN7EXAMPLE&auth-password=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY&s3-location-constraint=eu'
msg='failed against s3://bucket/p?auth-password=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY'
hasnt 'the secret key is masked in free text' "$(redact "${msg}")" 'wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY'
has   'and something is left to read'         "$(redact "${msg}")" 'failed against s3://bucket/p'
# Short values are region names and flags, not keys. Masking them would chew
# ordinary words out of the log lines for no security gain.
eq 'a short query value is left alone' 'in region eu' "$(redact 'in region eu')"

collect_secrets 'ssh://backupsvc:hunter2SuperSecretPassphrase@nas.example.internal/vol'
hasnt 'the ssh passphrase is masked' \
    "$(redact 'auth failed for backupsvc:hunter2SuperSecretPassphrase@nas.example.internal')" \
    'hunter2SuperSecretPassphrase'

collect_secrets ''
eq 'no URL means nothing to redact' 'untouched text' "$(redact 'untouched text')"

#------------------------------------------------------------------------------
section "json_escape(): the pure-bash encoder behind the NO_JQ payload"
#------------------------------------------------------------------------------
eq 'plain text is unchanged' 'hello world'  "$(json_escape 'hello world')"
eq 'double quotes'           'say \"hi\"'   "$(json_escape 'say "hi"')"
eq 'backslashes'             'C:\\\\path'   "$(json_escape 'C:\\path')"
# Backslash-then-quote is the ordering bug: escaping the quote first and the
# backslash afterwards produces \\" and shifts every following character.
eq 'a backslash before a quote' '\\\"'      "$(json_escape '\"')"
eq 'newline'                 'a\nb'        "$(json_escape "$(printf 'a\nb')")"
eq 'tab'                     'a\tb'        "$(json_escape "$(printf 'a\tb')")"
eq 'carriage return'         'a\rb'        "$(json_escape "$(printf 'a\rb')")"
# No short escape exists for these, so they must go out as \u00XX or the JSON is
# invalid -- Discord answers that with a 400 and no useful message.
eq 'a bell becomes \u0007'   'a\u0007b'    "$(json_escape "$(printf 'a\ab')")"
eq 'an escape becomes \u001b' '\u001b[0m'  "$(json_escape "$(printf '\033[0m')")"
eq 'multibyte text is passed through' 'ünïcödé — ✅' "$(json_escape 'ünïcödé — ✅')"
if have_jq; then
    yes_ 'the encoder produces a parseable JSON string' \
        jq -e . <<<"{\"v\":\"$(json_escape "$(printf 'quote " slash \\ tab \t bell \a done')")\"}"
fi

#------------------------------------------------------------------------------
section "truncate_text(): cut before encoding, never after"
#------------------------------------------------------------------------------
eq 'short text is untouched' 'abc' "$(truncate_text 'abc' 10)"
eq 'exact length is untouched' 'abcde' "$(truncate_text 'abcde' 5)"
t="$(truncate_text 'abcdefghij' 5)"
eq 'the ellipsis is part of the budget' 5 "${#t}"
eq 'and the text is cut to fit'         "abcd${ELLIPSIS}" "${t}"
eq 'a zero budget yields nothing'       '' "$(truncate_text 'abcdef' 0)"
# Multibyte input must never come back with half a character in it, whatever the
# locale bash was started in.
long="$(printf 'é%.0s' {1..300})"
t="$(truncate_text "${long}" 50)"
if have_jq; then
    yes_ 'a truncated multibyte string is still valid UTF-8' \
        jq -e . <<<"$(jq -n --arg v "${t}" '{v: $v}')"
fi
yes_ 'and it did get shorter' test "${#t}" -lt "${#long}"

#------------------------------------------------------------------------------
section "filters: DISCORD_NOTIFY_OPERATIONS and DISCORD_NOTIFY_ON"
#------------------------------------------------------------------------------
NOTIFY_OPERATIONS='Backup'
yes_ 'the default allows Backup'          operation_allowed 'Backup'
yes_ 'and is case-insensitive'            operation_allowed 'backup'
not  'the default excludes Restore'       operation_allowed 'Restore'
NOTIFY_OPERATIONS='Backup, Restore ,Compact'
yes_ 'a list member is allowed'           operation_allowed 'Restore'
yes_ 'whitespace around entries is fine'  operation_allowed 'Compact'
not  'a non-member is not'                operation_allowed 'Test'
NOTIFY_OPERATIONS='*'
yes_ 'a star allows everything'           operation_allowed 'DeleteAllButN'
NOTIFY_OPERATIONS='Backup'

NOTIFY_ON='all'
for r in Success Warning Error Fatal Unknown; do
    yes_ "all: ${r} notifies" severity_allowed "${r}"
done
NOTIFY_ON='warning'
not  'warning: Success is filtered out' severity_allowed 'Success'
yes_ 'warning: Warning notifies'        severity_allowed 'Warning'
yes_ 'warning: Error notifies'          severity_allowed 'Error'
yes_ 'warning: Fatal notifies'          severity_allowed 'Fatal'
not  'warning: Unknown is not a problem' severity_allowed 'Unknown'
NOTIFY_ON='error'
not  'error: Warning is filtered out'   severity_allowed 'Warning'
yes_ 'error: Error notifies'            severity_allowed 'Error'
yes_ 'error: Fatal notifies'            severity_allowed 'Fatal'
NOTIFY_ON='all'

#------------------------------------------------------------------------------
section "reading the result file: shallowest match wins"
#------------------------------------------------------------------------------
# BackendStatistics repeats MainOperation, ParsedResult and Duration with its
# OWN values. A recursive lookup that took any match rather than the shallowest
# would report the backend's 00:00:00 as the backup's duration.
RESULTFILE="${FIX}/success.json"
LOG_LINES=10
load_result
eq 'top-level Duration wins over BackendStatistics' '00:04:12.3456789' "${R[Duration]:-}"
eq 'ExaminedFiles'   '245671'        "${R[ExaminedFiles]:-}"
eq 'AddedFiles'      '34'            "${R[AddedFiles]:-}"
eq 'SizeOfExaminedFiles' '987654321098' "${R[SizeOfExaminedFiles]:-}"
# These exist only inside BackendStatistics, so the descent has to reach them.
eq 'BytesUploaded is found one level down'  '524288000'     "${R[BytesUploaded]:-}"
eq 'FilesUploaded is found one level down'  '11'            "${R[FilesUploaded]:-}"
eq 'TotalQuotaSpace is found one level down' '2199023255552' "${R[TotalQuotaSpace]:-}"
eq 'ParsedResult' 'Success' "${R[ParsedResult]:-}"

RESULTFILE="${FIX}/error.json"
load_result
eq 'the fatal fixture reports its own duration' '00:00:09.4410000' "${R[Duration]:-}"
eq 'and two errors'                             '2' "${R[ErrorsActualLength]:-}"
mapfile -t errs < <(result_lines Errors)
yes_ 'the error strings are readable' test "${#errs[@]}" -ge 1
has  'and name the backend failure' "${errs[0]}" 'AWS Access Key Id'
if [[ ${MODE} == "with-jq" ]]; then
    # A multi-line .NET exception has to arrive as ONE entry, or the fenced
    # block turns into a wall of orphaned stack frames.
    eq 'a multi-line entry stays one line' 1 "$(printf '%s' "${errs[0]}" | grep -c '')"
fi

RESULTFILE="${TMP}/not-json.txt"
printf 'ParsedResult: Success\nDuration: 00:02:00\nExaminedFiles: 17\n' >"${RESULTFILE}"
load_result
eq 'the plain-text result format still yields a duration' '00:02:00' "${R[Duration]:-}"
eq 'and a file count'                                     '17'       "${R[ExaminedFiles]:-}"

RESULTFILE="${TMP}/nope"
not 'a missing result file is not fatal, just empty' load_result
RESULTFILE=""

#------------------------------------------------------------------------------
section "end to end: what actually gets POSTed"
#------------------------------------------------------------------------------
WEBHOOK_STUB='https://discord.example/api/webhooks/1234567890/aTokenThatIsNotReal'
BASE_ENV=(
    DUPLICATI__EVENTNAME=AFTER
    DUPLICATI__OPERATIONNAME=Backup
    DUPLICATI__backup_name='Nightly NAS'
    DUPLICATI__LOCALPATH='/source/documents:/source/photos'
    DISCORD_HOSTNAME=tank
    "DISCORD_WEBHOOK_URL=${WEBHOOK_STUB}"
)

PAYLOAD=""
STDERR=""
SLEPT=""
ARGV=""
RC=0
declare -a CAPTURE_ARGS=()

# capture_test <VAR=VAL...> -- the same harness, but invoking the startup check.
capture_test() {
    CAPTURE_ARGS=(--test)
    capture "$@"
    CAPTURE_ARGS=()
}

# capture <VAR=VAL...> -- run the real main() with curl shadowed, and leave the
# payload in PAYLOAD. Nothing here touches the network or the filesystem outside
# ${TMP}.
capture() {
    local work="${TMP}/case"
    rm -rf "${work}"
    mkdir -p "${work}"
    # Arguments for main(), set by capture_test() below; empty for every other
    # case, which is what the real Duplicati invocation looks like.
    local -a MAIN_ARGS=("${CAPTURE_ARGS[@]}")
    (
        while [[ ${1-} == *=* ]]; do
            export "${1?}"
            shift
        done
        PAYLOAD_FILE="${work}/payload"
        CALLS_FILE="${work}/calls"

        # Stands in for curl -o <file> -w '%{http_code}'. CURL_CODES is a
        # space-separated script of responses, one per call, the last repeating
        # -- which is how the 429-then-204 retry is exercised without a server.
        curl() {
            local out_file="" i
            local -a argv=("$@")
            # Kept so a test can assert what did NOT end up here: everything in
            # argv is readable from /proc/<pid>/cmdline by any process running as
            # the same uid, and the token in a webhook URL is the credential.
            printf '%s\n' "$*" >"${work}/argv"
            for ((i = 0; i < ${#argv[@]}; i++)); do
                [[ ${argv[i]} == "-o" ]] && out_file="${argv[i + 1]}"
            done
            # The payload arrives on stdin because the mod passes
            # --data-binary @-, which is also why it never reaches the process
            # table on a real run.
            cat >>"${PAYLOAD_FILE}"
            local n
            n=$(($(cat "${CALLS_FILE}" 2>/dev/null || echo 0) + 1))
            printf '%s' "${n}" >"${CALLS_FILE}"
            local -a codes
            read -ra codes <<<"${CURL_CODES:-204}"
            local idx=$((n - 1))
            ((idx >= ${#codes[@]})) && idx=$((${#codes[@]} - 1))
            [[ -n ${out_file} ]] && printf '%s' "${CURL_BODY:-}" >"${out_file}"
            printf '%s' "${codes[idx]}"
            return "${CURL_RC:-0}"
        }
        # Never actually wait during a retry; just record that we would have.
        sleep() { printf '%s' "$1" >"${work}/slept"; }

        main "${MAIN_ARGS[@]}"
    ) >"${work}/out" 2>"${work}/err"
    RC=$?
    PAYLOAD="$(cat "${work}/payload" 2>/dev/null)"
    STDERR="$(cat "${work}/err" 2>/dev/null)"
    SLEPT="$(cat "${work}/slept" 2>/dev/null)"
    ARGV="$(cat "${work}/argv" 2>/dev/null)"
    CALLS="$(cat "${work}/calls" 2>/dev/null || echo 0)"
}

# jq_get <payload> <filter> -- only meaningful when the SUITE has jq.
jq_get() { jq -r "$2" <<<"$1" 2>/dev/null; }

# Every limit Discord documents, checked on a real payload.
check_limits() {
    local name=$1 p=$2
    have_jq || return 0
    if ! jq -e . >/dev/null 2>&1 <<<"${p}"; then
        no "${name}: valid JSON" "parseable JSON" "${p:0:200}"
        return 0
    fi
    ok "${name}: valid JSON"

    local bad
    bad="$(jq -r '
        def len: if . == null then 0 else (. | tostring | length) end;
        [
          (if (.content // "" | length) > 2000 then "content > 2000" else empty end),
          (.embeds // [] | .[] |
            (if (.title // "" | length) > 256 then "title > 256" else empty end),
            (if (.description // "" | length) > 4096 then "description > 4096" else empty end),
            (if (.footer.text // "" | length) > 2048 then "footer > 2048" else empty end),
            (if ((.fields // []) | length) > 25 then "more than 25 fields" else empty end),
            ((.fields // []) | .[] |
              (if (.name | length) > 256 then "field name > 256" else empty end),
              (if (.value | length) > 1024 then "field value > 1024" else empty end)),
            (if ((.title // "" | length)
                 + (.description // "" | length)
                 + (.footer.text // "" | length)
                 + ([(.fields // [])[] | (.name | length) + (.value | length)] | add // 0)) > 6000
             then "embed total > 6000" else empty end))
        ] | join("; ")
    ' <<<"${p}" 2>/dev/null)"
    if [[ -z ${bad} ]]; then
        ok "${name}: inside every Discord limit"
    else
        no "${name}: inside every Discord limit" "no violations" "${bad}"
    fi
}

# --- clean success ------------------------------------------------------------
capture "${BASE_ENV[@]}" \
    DUPLICATI__PARSED_RESULT=Success \
    "DUPLICATI__RESULTFILE=${FIX}/success.json" \
    DUPLICATI__REMOTEURL='s3://acme-offsite-backups/nas?auth-username=AKIAIOSFODNN7EXAMPLE&auth-password=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY'
eq 'success: always exits 0' 0 "${RC}"
yes_ 'success: something was sent' test -n "${PAYLOAD}"
check_limits 'success' "${PAYLOAD}"
hasnt 'success: the S3 secret is nowhere in the payload' "${PAYLOAD}" 'wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY'
hasnt 'success: nor is the access key id'                "${PAYLOAD}" 'AKIAIOSFODNN7EXAMPLE'
has   'success: the destination is still shown'          "${PAYLOAD}" 's3://acme-offsite-backups/nas'
has   'success: the backup name is in there'             "${PAYLOAD}" 'Nightly NAS'
if [[ ${MODE} == "with-jq" ]] && have_jq; then
    eq 'success: the green colour'   3066993 "$(jq_get "${PAYLOAD}" '.embeds[0].color')"
    eq 'success: the tick and title' '✅ Nightly NAS — Success' "$(jq_get "${PAYLOAD}" '.embeds[0].title')"
    eq 'success: the footer'         'tank • Duplicati' "$(jq_get "${PAYLOAD}" '.embeds[0].footer.text')"
    eq 'success: no description on a clean run' 'null' "$(jq_get "${PAYLOAD}" '.embeds[0].description')"
    eq 'success: the default webhook name' 'Duplicati' "$(jq_get "${PAYLOAD}" '.username')"
    eq 'success: duration is normalised' '4m 12s' \
        "$(jq_get "${PAYLOAD}" '.embeds[0].fields[] | select(.name=="Duration") | .value')"
    eq 'success: sizes are human-readable' '919.8 GiB' \
        "$(jq_get "${PAYLOAD}" '.embeds[0].fields[] | select(.name=="Size examined") | .value')"
    eq 'success: bytes uploaded' '500.0 MiB' \
        "$(jq_get "${PAYLOAD}" '.embeds[0].fields[] | select(.name=="Uploaded") | .value')"
    eq 'success: quota used of total' '1.0 TiB of 2.0 TiB (50%)' \
        "$(jq_get "${PAYLOAD}" '.embeds[0].fields[] | select(.name=="Quota used") | .value')"
    eq 'success: source paths become a comma list' '/source/documents, /source/photos' \
        "$(jq_get "${PAYLOAD}" '.embeds[0].fields[] | select(.name=="Source") | .value')"
    eq 'success: a zero error count is not rendered' '' \
        "$(jq_get "${PAYLOAD}" '.embeds[0].fields[] | select(.name=="Errors") | .value')"
    eq 'success: an ISO-8601 UTC timestamp' 'true' \
        "$(jq_get "${PAYLOAD}" '.embeds[0].timestamp | test("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$")')"
    # No field may be rendered with a placeholder value; absent means absent.
    eq 'success: no N/A rows' '' \
        "$(jq_get "${PAYLOAD}" '[.embeds[0].fields[] | select(.value == "" or .value == "N/A" or .value == "null")] | .[].name')"
elif have_jq; then
    eq 'no-jq: a flat content message, no embed' 'null' "$(jq_get "${PAYLOAD}" '.embeds')"
    yes_ 'no-jq: content is present' test -n "$(jq_get "${PAYLOAD}" '.content')"
    has  'no-jq: and still carries the result' "$(jq_get "${PAYLOAD}" '.content')" 'Success'
fi

# --- success with warnings ----------------------------------------------------
capture "${BASE_ENV[@]}" \
    DUPLICATI__PARSED_RESULT=Warning \
    "DUPLICATI__RESULTFILE=${FIX}/warnings.json" \
    DUPLICATI__REMOTEURL='ssh://backupsvc:hunter2SuperSecretPassphrase@nas.example.internal/vol1'
eq 'warning: always exits 0' 0 "${RC}"
check_limits 'warning' "${PAYLOAD}"
hasnt 'warning: the ssh passphrase is nowhere in the payload' "${PAYLOAD}" 'hunter2SuperSecretPassphrase'
has   'warning: the host is still shown' "${PAYLOAD}" 'nas.example.internal'
if [[ ${MODE} == "with-jq" ]] && have_jq; then
    eq 'warning: the amber colour' 15844367 "$(jq_get "${PAYLOAD}" '.embeds[0].color')"
    has 'warning: the warning emoji' "$(jq_get "${PAYLOAD}" '.embeds[0].title')" '⚠️'
    d="$(jq_get "${PAYLOAD}" '.embeds[0].description')"
    has 'warning: a fenced code block' "${d}" '```'
    has 'warning: listing the warnings'  "${d}" 'Warnings:'
    has 'warning: with the actual text'  "${d}" 'PathProcessingFailed'
    # The fixture's warnings contain a double quote and a backslash on purpose:
    # this is exactly what a concatenated payload gets wrong.
    has 'warning: a quote inside a log line survives' "${d}" '"quoted" name.db'
    has 'warning: so does a backslash'                "${d}" 'secret\backslash.txt'
    eq  'warning: the count is shown'  '3' \
        "$(jq_get "${PAYLOAD}" '.embeds[0].fields[] | select(.name=="Warnings") | .value')"
    eq  'warning: and a zero error count too, on a non-success result' '0' \
        "$(jq_get "${PAYLOAD}" '.embeds[0].fields[] | select(.name=="Errors") | .value')"
fi

# --- hard error ---------------------------------------------------------------
capture "${BASE_ENV[@]}" \
    DUPLICATI__PARSED_RESULT=Fatal \
    "DUPLICATI__RESULTFILE=${FIX}/error.json" \
    DUPLICATI__REMOTEURL='s3://acme-offsite-backups/nas' \
    DISCORD_MENTION_ON_ERROR='<@&123456789012345678>'
eq 'fatal: always exits 0' 0 "${RC}"
check_limits 'fatal' "${PAYLOAD}"
has 'fatal: the mention is on the message' "${PAYLOAD}" '<@&123456789012345678>'
if [[ ${MODE} == "with-jq" ]] && have_jq; then
    eq 'fatal: the fatal colour' 10038562 "$(jq_get "${PAYLOAD}" '.embeds[0].color')"
    has 'fatal: the skull'       "$(jq_get "${PAYLOAD}" '.embeds[0].title')" '💀'
    eq  'fatal: the mention is in content, where Discord actually notifies' \
        '<@&123456789012345678>' "$(jq_get "${PAYLOAD}" '.content')"
    has 'fatal: the description names the failure' \
        "$(jq_get "${PAYLOAD}" '.embeds[0].description')" 'AWS Access Key Id'
    eq  'fatal: two errors counted' '2' \
        "$(jq_get "${PAYLOAD}" '.embeds[0].fields[] | select(.name=="Errors") | .value')"
fi

# A mention must NOT fire on a warning; a ping people learn to ignore is worse
# than no ping.
capture "${BASE_ENV[@]}" \
    DUPLICATI__PARSED_RESULT=Warning \
    "DUPLICATI__RESULTFILE=${FIX}/warnings.json" \
    DISCORD_MENTION_ON_ERROR='<@&123456789012345678>'
hasnt 'a warning does not ping anyone' "${PAYLOAD}" '<@&123456789012345678>'

# --- credentials everywhere ---------------------------------------------------
CRED_URL='s3://acme-offsite-backups/nas?s3-server-name=s3.eu-central-1.amazonaws.com&auth-username=AKIAIOSFODNN7EXAMPLE&auth-password=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY'
capture "${BASE_ENV[@]}" \
    DUPLICATI__PARSED_RESULT=Error \
    "DUPLICATI__RESULTFILE=${FIX}/credentials.json" \
    "DUPLICATI__REMOTEURL=${CRED_URL}"
eq 'credentials: always exits 0' 0 "${RC}"
check_limits 'credentials' "${PAYLOAD}"
# The fixture puts the same secrets in THREE places: the destination URL, a
# warning line and two error lines. All three have to be clean.
for secret in 'wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY' 'hunter2SuperSecretPassphrase' 'auth-password='; do
    hasnt "credentials: '${secret}' does not reach Discord" "${PAYLOAD}" "${secret}"
done
has 'credentials: the destination is still identifiable' "${PAYLOAD}" 'acme-offsite-backups/nas'

# --- filters, end to end ------------------------------------------------------
capture "${BASE_ENV[@]}" \
    DUPLICATI__PARSED_RESULT=Success \
    "DUPLICATI__RESULTFILE=${FIX}/success.json" \
    DISCORD_NOTIFY_ON=error
eq 'DISCORD_NOTIFY_ON=error: a success sends nothing' '' "${PAYLOAD}"
eq 'and still exits 0'                                0  "${RC}"

capture "${BASE_ENV[@]}" \
    DUPLICATI__OPERATIONNAME=Compact \
    DUPLICATI__PARSED_RESULT=Success \
    "DUPLICATI__RESULTFILE=${FIX}/success.json"
eq 'the default operation allowlist drops Compact' '' "${PAYLOAD}"

capture "${BASE_ENV[@]}" \
    DUPLICATI__OPERATIONNAME=Compact \
    DUPLICATI__PARSED_RESULT=Success \
    "DUPLICATI__RESULTFILE=${FIX}/success.json" \
    'DISCORD_NOTIFY_OPERATIONS=*'
yes_ 'DISCORD_NOTIFY_OPERATIONS=* lets Compact through' test -n "${PAYLOAD}"

capture "${BASE_ENV[@]}" \
    DUPLICATI__EVENTNAME=BEFORE \
    DUPLICATI__PARSED_RESULT=Success \
    "DUPLICATI__RESULTFILE=${FIX}/success.json"
eq 'the BEFORE event sends nothing' '' "${PAYLOAD}"

capture \
    DUPLICATI__EVENTNAME=AFTER \
    DUPLICATI__OPERATIONNAME=Backup \
    DUPLICATI__PARSED_RESULT=Success \
    "DUPLICATI__RESULTFILE=${FIX}/success.json"
eq 'no webhook configured: sends nothing' '' "${PAYLOAD}"
eq 'and says nothing about it'            '' "${STDERR}"
eq 'and still exits 0'                    0  "${RC}"

#------------------------------------------------------------------------------
section "the webhook URL never reaches the process table"
#------------------------------------------------------------------------------
# The payload is on stdin so a large embed cannot hit ARG_MAX. The URL is passed
# through --config for a different reason: it IS the secret, and argv is
# world-readable to every process running as this uid via /proc/<pid>/cmdline.
capture "${BASE_ENV[@]}" \
    DUPLICATI__PARSED_RESULT=Success \
    "DUPLICATI__RESULTFILE=${FIX}/success.json" \
    DUPLICATI__REMOTEURL='s3://bucket/path'
yes_ 'curl was actually invoked' test -n "${ARGV}"
hasnt 'the webhook token is not in curl argv' "${ARGV}" 'aTokenThatIsNotReal'
hasnt 'nor is the URL in any form'            "${ARGV}" 'discord.example'
has   'it arrives through --config instead'   "${ARGV}" '--config'
# And the payload is not in argv either, which is what --data-binary @- buys.
hasnt 'the payload is not in curl argv'       "${ARGV}" 'Nightly NAS'
has   'it arrives on stdin instead'           "${ARGV}" '--data-binary @-'

#------------------------------------------------------------------------------
section "webhook resolution: env, then file, then /config"
#------------------------------------------------------------------------------
printf 'https://discord.example/api/webhooks/from/a-file\n\n' >"${TMP}/hook"
printf 'https://discord.example/api/webhooks/from/config\n' >"${TMP}/config-hook"

# resolved [--config-file <path>] <VAR=VAL...>
#
# The /config/discord-webhook.url fallback is a constant in the mod, on purpose:
# a second DISCORD_WEBHOOK_*_FILE variable one character from the documented one
# is a trap. The tests reach it by assigning WEBHOOK_FILE after configure().
resolved() {
    local cfg=""
    if [[ ${1-} == "--config-file" ]]; then
        cfg=$2
        shift 2
    fi
    (
        while [[ ${1-} == *=* ]]; do
            export "${1?}"
            shift
        done
        configure
        if [[ -n ${cfg} ]]; then
            WEBHOOK_FILE="${cfg}"
            WEBHOOK="$(resolve_webhook)"
        fi
        printf '%s' "${WEBHOOK}"
    )
}
eq 'the environment variable wins' 'https://discord.example/env' \
    "$(resolved DISCORD_WEBHOOK_URL=https://discord.example/env "DISCORD_WEBHOOK_URL_FILE=${TMP}/hook")"
eq 'then the _FILE variable' 'https://discord.example/api/webhooks/from/a-file' \
    "$(resolved "DISCORD_WEBHOOK_URL_FILE=${TMP}/hook")"
eq 'trailing newlines are trimmed' 'https://discord.example/api/webhooks/from/a-file' \
    "$(resolved "DISCORD_WEBHOOK_URL_FILE=${TMP}/hook")"
eq 'then /config/discord-webhook.url' 'https://discord.example/api/webhooks/from/config' \
    "$(resolved --config-file "${TMP}/config-hook")"
eq 'nothing configured means empty' '' "$(resolved --config-file "${TMP}/absent")"
printf 'https://discord.example/crlf\r\n' >"${TMP}/crlf-hook"
eq 'a CR from a file written on Windows is stripped' 'https://discord.example/crlf' \
    "$(resolved "DISCORD_WEBHOOK_URL_FILE=${TMP}/crlf-hook")"

#------------------------------------------------------------------------------
section "delivery: retry once on 429, and never fail the backup"
#------------------------------------------------------------------------------
capture "${BASE_ENV[@]}" \
    DUPLICATI__PARSED_RESULT=Success \
    "DUPLICATI__RESULTFILE=${FIX}/success.json" \
    'CURL_CODES=429 204' \
    'CURL_BODY={"message":"You are being rate limited.","retry_after":2.5,"global":false}'
eq '429 then 204: two attempts were made' 2 "${CALLS}"
eq 'and it honoured retry_after (2.5s rounded up)' 3 "${SLEPT}"
eq 'and the backup still succeeded'               0 "${RC}"

capture "${BASE_ENV[@]}" \
    DUPLICATI__PARSED_RESULT=Success \
    "DUPLICATI__RESULTFILE=${FIX}/success.json" \
    'CURL_CODES=429 429'
eq 'a second 429 is not retried again' 2 "${CALLS}"
eq 'and still exits 0'                 0 "${RC}"

capture "${BASE_ENV[@]}" \
    DUPLICATI__PARSED_RESULT=Success \
    "DUPLICATI__RESULTFILE=${FIX}/success.json" \
    CURL_CODES=404
eq 'a 404 exits 0 -- a dead webhook is not a failed backup' 0 "${RC}"
has 'and explains what a 404 means' "${STDERR}" 'the webhook URL is wrong'

capture "${BASE_ENV[@]}" \
    DUPLICATI__PARSED_RESULT=Success \
    "DUPLICATI__RESULTFILE=${FIX}/success.json" \
    CURL_RC=28
eq 'a curl timeout exits 0 as well' 0 "${RC}"
has 'and says curl failed'          "${STDERR}" 'curl failed (exit 28)'

# THE regression that matters most. Whatever is thrown at this script, Duplicati
# must see a zero exit -- anything else and a working backup gets recorded as
# failed, in Duplicati's log and in every other notification channel.
capture DUPLICATI__EVENTNAME=AFTER DUPLICATI__OPERATIONNAME=Backup \
    DUPLICATI__PARSED_RESULT='' \
    DUPLICATI__RESULTFILE=/nonexistent/result.json \
    DUPLICATI__REMOTEURL='not a url at all' \
    "DISCORD_WEBHOOK_URL=${WEBHOOK_STUB}"
eq 'garbage in: still exits 0' 0 "${RC}"
if have_jq && [[ ${MODE} == "with-jq" ]]; then
    eq 'and an unparseable result becomes the Unknown colour' 9807270 \
        "$(jq_get "${PAYLOAD}" '.embeds[0].color')"
fi

capture "${BASE_ENV[@]}" \
    DUPLICATI__PARSED_RESULT=Success \
    "DUPLICATI__RESULTFILE=${FIX}/success.json" \
    DISCORD_LOG_LINES=notanumber DISCORD_TIMEOUT=alsonot
eq 'nonsense in the numeric knobs is clamped, not fatal' 0 "${RC}"
yes_ 'and it still sent something' test -n "${PAYLOAD}"

#------------------------------------------------------------------------------
section "Discord's 6000-character embed cap"
#------------------------------------------------------------------------------
# A backup name and a source list long enough that the naive payload would be
# rejected outright. The mod must trim rather than send something Discord 400s.
long_name="$(printf 'A%.0s' {1..900})"
long_paths="$(printf '/very/long/source/path/number-%s:' {1..120})"
capture \
    DUPLICATI__EVENTNAME=AFTER \
    DUPLICATI__OPERATIONNAME=Backup \
    DUPLICATI__PARSED_RESULT=Fatal \
    "DUPLICATI__RESULTFILE=${FIX}/error.json" \
    "DUPLICATI__backup_name=${long_name}" \
    "DUPLICATI__LOCALPATH=${long_paths}" \
    DUPLICATI__REMOTEURL='s3://bucket/path' \
    "DISCORD_WEBHOOK_URL=${WEBHOOK_STUB}" \
    DISCORD_LOG_LINES=50
eq 'an oversized message still exits 0' 0 "${RC}"
check_limits 'oversized' "${PAYLOAD}"

# The case above does NOT exercise the 6000 cap: per-field truncation alone
# keeps it to about 2,500 characters. Verified by mutation -- deleting the total
# budget left the whole suite green -- so here is one that genuinely needs it.
#
# Title (256) + footer + a 1024-character Destination + a 1024-character Source
# is roughly 2,400. Add a description that would take its full 4,096 and the
# embed lands near 6,500. Only the clamp in build_description(), which gives the
# description whatever the fields left behind, keeps that legal.
big="${TMP}/oversized-result.json"
{
    printf '{"MainOperation":"Backup","ParsedResult":"Fatal","Duration":"00:00:09.4410000",'
    printf '"ExaminedFiles":12,"ErrorsActualLength":40,"WarningsActualLength":0,'
    printf '"Warnings":[],"Errors":['
    filler="$(printf 'x%.0s' {1..200})"
    for i in $(seq 1 40); do
        ((i > 1)) && printf ','
        printf '"2026-08-22 02:00:%02d +02 - [Error-Duplicati.Library.Main.Operation.BackupHandler-Failed]: %s"' \
            "${i}" "${filler}"
    done
    printf ']}'
} >"${big}"

capture \
    DUPLICATI__EVENTNAME=AFTER \
    DUPLICATI__OPERATIONNAME=Backup \
    DUPLICATI__PARSED_RESULT=Fatal \
    "DUPLICATI__RESULTFILE=${big}" \
    "DUPLICATI__backup_name=${long_name}" \
    "DUPLICATI__LOCALPATH=${long_paths}" \
    "DUPLICATI__REMOTEURL=s3://bucket/$(printf 'd%.0s' {1..1500})" \
    "DISCORD_WEBHOOK_URL=${WEBHOOK_STUB}" \
    DISCORD_LOG_LINES=50
eq 'a genuinely oversized embed still exits 0' 0 "${RC}"
check_limits 'over-6000' "${PAYLOAD}"
if [[ ${MODE} == "with-jq" ]] && have_jq; then
    total="$(jq_get "${PAYLOAD}" '
        .embeds[0] | (.title | length) + (.description // "" | length)
        + (.footer.text | length) + ([.fields[] | (.name|length) + (.value|length)] | add // 0)')"
    yes_ 'the embed really is near the cap, not trivially small' test "${total}" -gt 4000
    yes_ 'and still inside it'                                   test "${total}" -le 6000
    # Proves the clamp did the trimming, rather than the description happening
    # to be short: unclamped it would have taken the full 4096.
    dlen="$(jq_get "${PAYLOAD}" '.embeds[0].description | length')"
    yes_ 'the description was trimmed to the room the fields left' test "${dlen}" -lt 4096
fi

#------------------------------------------------------------------------------
section "configuration mistakes are reported, not absorbed"
#------------------------------------------------------------------------------
# Both filters used to fail silently on a typo, in opposite directions.
warned() { # warned <VAR=VAL...> -> whatever configure() wrote to stderr
    (
        while [[ ${1-} == *=* ]]; do
            export "${1?}"
            shift
        done
        # stderr only: the warnings are what is under test, not the config dump.
        { configure >/dev/null; } 2>&1
    )
}
has 'a misspelled DISCORD_NOTIFY_ON is named' \
    "$(warned DISCORD_NOTIFY_ON=errors)" "DISCORD_NOTIFY_ON='errors' is not one of"
has 'and says what it fell back to' \
    "$(warned DISCORD_NOTIFY_ON=errors)" "using 'all'"
eq 'a correct value says nothing' '' "$(warned DISCORD_NOTIFY_ON=error)"
eq 'and neither does the default'  '' "$(warned)"
has 'a misspelled operation is named' \
    "$(warned DISCORD_NOTIFY_OPERATIONS=backups)" "lists 'backups', which is not a Duplicati operation"
has 'and the known names are offered' \
    "$(warned DISCORD_NOTIFY_OPERATIONS=backups)" 'DeleteAllButN'
eq 'a real operation name is quiet' '' "$(warned DISCORD_NOTIFY_OPERATIONS=Compact)"
eq 'a list of real names is quiet'  '' "$(warned 'DISCORD_NOTIFY_OPERATIONS=Backup, Compact ,Test')"
eq 'a star is quiet'                '' "$(warned 'DISCORD_NOTIFY_OPERATIONS=*')"
# Warned about, not rejected -- Duplicati has added operations before.
capture "${BASE_ENV[@]}" \
    DUPLICATI__OPERATIONNAME=SomeFutureOperation \
    DUPLICATI__PARSED_RESULT=Success \
    "DUPLICATI__RESULTFILE=${FIX}/success.json" \
    DISCORD_NOTIFY_OPERATIONS=SomeFutureOperation
yes_ 'an unknown operation is still honoured, not rejected' test -n "${PAYLOAD}"

#------------------------------------------------------------------------------
section "DUPLICATI__EVENTNAME casing"
#------------------------------------------------------------------------------
# Every other comparison in the mod folds case; this one did not.
for ev in AFTER after After aFtEr; do
    capture "${BASE_ENV[@]}" \
        "DUPLICATI__EVENTNAME=${ev}" \
        DUPLICATI__PARSED_RESULT=Success \
        "DUPLICATI__RESULTFILE=${FIX}/success.json"
    yes_ "EVENTNAME='${ev}' sends" test -n "${PAYLOAD}"
done
for ev in BEFORE before ''; do
    capture "${BASE_ENV[@]}" \
        "DUPLICATI__EVENTNAME=${ev}" \
        DUPLICATI__PARSED_RESULT=Success \
        "DUPLICATI__RESULTFILE=${FIX}/success.json"
    eq "EVENTNAME='${ev}' sends nothing" '' "${PAYLOAD}"
done

#------------------------------------------------------------------------------
section "build_payload() does not accumulate across calls"
#------------------------------------------------------------------------------
# FIELDS and EMBED_CHARS are globals so add_field() can reach them, which made a
# second call in one process double-count every field.
RESULTFILE="${FIX}/success.json"
RESULT="Success"
OPERATION="Backup"
BACKUP_NAME="Nightly NAS"
REMOTEURL="s3://bucket/path"
LOCALPATH="/source/documents"
HOST="tank"
MENTION=""
AVATAR_URL=""
USERNAME="Duplicati"
LOG_LINES=10
load_result
# Redirected, NOT captured with $( ): a command substitution runs in a subshell
# and throws the global mutations away, so the accumulation this guards against
# would be invisible. main() happens to call it that way, which is why the bug
# was latent rather than live.
build_payload >"${TMP}/payload-1"
build_payload >"${TMP}/payload-2"
# The timestamp is stripped before comparing: each payload stamps date -u at
# build time, so two calls that straddle a second differ for a reason that has
# nothing to do with what this test is about. Comparing them raw passed by luck
# and failed roughly once per second of wall clock.
strip_ts() { sed 's/"timestamp":"[^"]*"/"timestamp":"T"/' "$1"; }
one="$(strip_ts "${TMP}/payload-1")"
two="$(strip_ts "${TMP}/payload-2")"
eq 'a second call produces the same payload' "${one}" "${two}"
if have_jq && [[ ${MODE} == "with-jq" ]]; then
    eq 'and not a doubled field list' \
        "$(jq_get "${one}" '.embeds[0].fields | length')" \
        "$(jq_get "${two}" '.embeds[0].fields | length')"
fi

#------------------------------------------------------------------------------
section "DISCORD_TEST_ON_START: the startup check"
#------------------------------------------------------------------------------
# Invoked as `duplicati-discord.sh --test` by the second init oneshot. It has no
# operation, no result file and no DUPLICATI__ variables at all -- that is what
# a container start looks like.
capture_test \
    DISCORD_HOSTNAME=tank \
    "DISCORD_WEBHOOK_URL=${WEBHOOK_STUB}"
eq 'test: exits 0' 0 "${RC}"
yes_ 'test: something was sent' test -n "${PAYLOAD}"
check_limits 'test' "${PAYLOAD}"
has 'test: says it is a test'            "${PAYLOAD}" 'Test notification'
has 'test: names the manual step'        "${PAYLOAD}" 'run-script-after=/usr/local/bin/duplicati-discord.sh'
has 'test: and how to turn it off'       "${PAYLOAD}" 'DISCORD_TEST_ON_START'
hasnt 'test: the webhook token is not in curl argv' "${ARGV}" 'aTokenThatIsNotReal'
if [[ ${MODE} == "with-jq" ]] && have_jq; then
    eq 'test: its own colour, not a result colour' 5793266 "$(jq_get "${PAYLOAD}" '.embeds[0].color')"
    has 'test: the bell, not a result emoji' "$(jq_get "${PAYLOAD}" '.embeds[0].title')" '🔔'
    eq 'test: the footer still carries the host' 'tank • Duplicati' \
        "$(jq_get "${PAYLOAD}" '.embeds[0].footer.text')"
    # A test is not a backup outcome; rendering zeroed statistics would invite
    # exactly the misreading this message exists to avoid.
    eq 'test: no statistics fields' 'null' "$(jq_get "${PAYLOAD}" '.embeds[0].fields')"
fi

# The filters must not silence it: someone asking whether the webhook works
# wants an answer, not silence because they also filtered to errors only.
capture_test \
    "DISCORD_WEBHOOK_URL=${WEBHOOK_STUB}" \
    DISCORD_NOTIFY_ON=error DISCORD_NOTIFY_OPERATIONS=Restore
yes_ 'test: severity and operation filters do not suppress it' test -n "${PAYLOAD}"

# ...but an unconfigured webhook must say so, loudly. This runs once at start,
# into the container log, which is exactly where someone who just enabled it
# will be looking.
capture_test DISCORD_HOSTNAME=tank
eq 'test: no webhook sends nothing'  '' "${PAYLOAD}"
eq 'test: and still exits 0'          0 "${RC}"
has 'test: but complains, unlike the per-backup path' "${STDERR}" 'no webhook is configured'
has 'test: and names all three sources' "${STDERR}" 'DISCORD_WEBHOOK_URL_FILE'

# A dead webhook cannot fail the oneshot, which would block container startup.
capture_test "DISCORD_WEBHOOK_URL=${WEBHOOK_STUB}" CURL_CODES=404
eq 'test: a 404 still exits 0' 0 "${RC}"
capture_test "DISCORD_WEBHOOK_URL=${WEBHOOK_STUB}" CURL_RC=6
eq 'test: a DNS failure still exits 0' 0 "${RC}"

# And the ordinary path must be untouched by all of the above.
capture "${BASE_ENV[@]}" \
    DUPLICATI__PARSED_RESULT=Success \
    "DUPLICATI__RESULTFILE=${FIX}/success.json"
if [[ ${MODE} == "with-jq" ]] && have_jq; then
    eq 'a real notification is still green, not blurple' 3066993 \
        "$(jq_get "${PAYLOAD}" '.embeds[0].color')"
    yes_ 'and still carries its statistics' test \
        "$(jq_get "${PAYLOAD}" '.embeds[0].fields | length')" -gt 5
fi

#------------------------------------------------------------------------------
printf '\n'
if ((FAIL)); then
    printf '%d passed, %d FAILED (%s)\n' "${PASS}" "${FAIL}" "${MODE}"
    printf '  - %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
printf '%d passed, 0 failed (%s)\n' "${PASS}" "${MODE}"
