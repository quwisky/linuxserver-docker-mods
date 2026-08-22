#!/bin/bash
# End-to-end smoke test: the real duplicati-discord.sh, invoked the way Duplicati
# invokes it, against a Caddy stub standing in for Discord.
#
# Unlike test/docker-compose.test.yml this needs no bind mounts -- everything is
# baked into throwaway images from tar-piped build contexts -- so it runs
# unchanged in CI and on hosts where the docker daemon cannot see the working
# tree. Needs only a working docker.
#
#   bash test/smoke.sh
#
# The stub logs each request body verbatim (see stubs/Caddyfile.discord-ok), so
# these assertions are made against the bytes that actually crossed the network,
# not against what the script believed it was building. Roughly a minute.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../root/usr/local/bin/duplicati-discord.sh"
WORK="$(mktemp -d)"
NET=duplicati-discord-smoke
RUNNER=dupsmoke/runner
FAILED=0

cleanup() {
    docker rm -f dup-hook dup-mod >/dev/null 2>&1
    docker network rm "${NET}" >/dev/null 2>&1
    rm -rf "${WORK}"
}
trap cleanup EXIT

# macOS tars xattrs and AppleDouble files into the build context and the daemon
# then fails on `lsetxattr: xattr "com.apple.provenance"`. GNU tar has neither
# flag, so probe rather than assume.
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
    local d
    d="${WORK}/$(basename "${cf}")"
    mkdir -p "${d}"
    cp "${cf}" "${d}/Caddyfile"
    printf 'FROM caddy:2-alpine\nCOPY Caddyfile /etc/caddy/Caddyfile\n' >"${d}/Dockerfile"
    ctx "${d}" | docker build -q -t "${tag}" - >/dev/null
}

# bash + curl + jq, i.e. what the mod's init oneshot arranges for on a real
# linuxserver image.
build_runner() {
    local d="${WORK}/runner"
    mkdir -p "${d}/fixtures"
    cp "${SCRIPT}" "${d}/duplicati-discord.sh"
    cp "${HERE}"/fixtures/*.json "${d}/fixtures/"
    # The startup-test oneshot, so scenario 10 drives the real s6 script rather
    # than a re-implementation of what it is supposed to do.
    cp "${HERE}/../root/etc/s6-overlay/s6-rc.d/init-mod-duplicati-discord-notify-mod-test/run" \
        "${d}/test-oneshot.sh"
    # /usr/bin/with-contenv exists only in an LSIO image, and both scripts here
    # carry it as their shebang. The stand-in baked in below is what the real one
    # reduces to once the container environment is already in place. Without it
    # the init oneshot cannot exec the notification script at all -- and would
    # still exit 0, so the scenario driving it would pass while testing nothing.
    printf 'FROM bash:5\nRUN apk add --no-cache curl jq && printf "#!/bin/sh\\nexec \\"\\$@\\"\\n" >/usr/bin/with-contenv && chmod +x /usr/bin/with-contenv\nCOPY duplicati-discord.sh /usr/local/bin/duplicati-discord.sh\nCOPY test-oneshot.sh /test-oneshot.sh\nCOPY fixtures /fixtures\nRUN chmod +x /usr/local/bin/duplicati-discord.sh /test-oneshot.sh && ln -s /usr/local/bin/duplicati-discord.sh /duplicati-discord.sh\n' >"${d}/Dockerfile"
    ctx "${d}" | docker build -q -t "${RUNNER}" - >/dev/null
}

say() { printf '\n\033[1m### %s\033[0m\n' "$*"; }
dump() {
    while IFS= read -r _line; do printf '    | %s\n' "${_line}"; done <<<"$1"
}

pass() { printf '  ok   %s\n' "$1"; }
fail() {
    printf '  FAIL %s\n         %s\n' "$1" "$2"
    FAILED=$((FAILED + 1))
}
expect() { # expect <haystack> <name> <extended-regex>
    if grep -qE "$3" <<<"$1"; then pass "$2"; else fail "$2" "no match for: $3"; fi
}
refute() { # refute <haystack> <name> <extended-regex>
    if grep -qE "$3" <<<"$1"; then fail "$2" "unexpected match for: $3"; else pass "$2 (absent)"; fi
}
eq() {
    if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}

# The request bodies the stub actually received, one per line, decoded out of
# its JSON access log. jq runs inside the runner image so the host needs none.
bodies() {
    docker logs dup-hook 2>&1 |
        docker run --rm -i "${RUNNER}" jq -r 'select(.body != null) | .body' 2>/dev/null
}
request_count() { bodies | grep -c . ; }
content_types() {
    docker logs dup-hook 2>&1 |
        docker run --rm -i "${RUNNER}" jq -r 'select(.body != null) | .request.headers["Content-Type"][0] // "none"' 2>/dev/null
}

start_stub() { # start_stub <image>
    docker rm -f dup-hook >/dev/null 2>&1
    docker run -d --name dup-hook --network "${NET}" --network-alias discord-stub "$1" >/dev/null
    sleep 2
}

# run_mod <extra env...> -- one invocation, exactly as Duplicati would make it.
run_mod() {
    local -a envs=(
        -e DUPLICATI__EVENTNAME=AFTER
        -e DUPLICATI__OPERATIONNAME=Backup
        -e "DUPLICATI__backup_name=Nightly NAS"
        -e DUPLICATI__LOCALPATH=/source/documents:/source/photos
        -e DISCORD_HOSTNAME=tank
        -e DISCORD_TIMEOUT=10
        -e "DISCORD_WEBHOOK_URL=http://discord-stub:8080/api/webhooks/1234567890/aTokenThatIsNotReal"
    )
    local e
    for e in "$@"; do envs+=(-e "${e}"); done
    docker rm -f dup-mod >/dev/null 2>&1
    docker run --name dup-mod --network "${NET}" "${envs[@]}" \
        "${RUNNER}" bash /duplicati-discord.sh >"${WORK}/out" 2>"${WORK}/err"
    MOD_RC=$?
    MODLOG="$(cat "${WORK}/out" "${WORK}/err" 2>/dev/null)"
}

#------------------------------------------------------------------------------
docker network create "${NET}" >/dev/null 2>&1
build_runner
build_stub dupsmoke/discord-ok "${HERE}/stubs/Caddyfile.discord-ok"
build_stub dupsmoke/discord-429 "${HERE}/stubs/Caddyfile.discord-429"
build_stub dupsmoke/discord-404 "${HERE}/stubs/Caddyfile.discord-404"

CRED_URL='s3://acme-offsite-backups/nas?s3-server-name=s3.eu-central-1.amazonaws.com&auth-username=AKIAIOSFODNN7EXAMPLE&auth-password=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY'

#------------------------------------------------------------------------------
say "Scenario 1: a successful backup posts one colour-coded embed"
start_stub dupsmoke/discord-ok
run_mod DUPLICATI__PARSED_RESULT=Success \
    DUPLICATI__RESULTFILE=/fixtures/success.json \
    "DUPLICATI__REMOTEURL=${CRED_URL}"
BODY="$(bodies)"
dump "${BODY}"
eq 'the script exits 0, so Duplicati records the backup as successful' 0 "${MOD_RC}"
eq 'exactly one request reached the webhook' 1 "$(request_count)"
eq 'and it was sent as application/json' 'application/json' "$(content_types)"
expect "${BODY}" 'the body is an embed'          '"embeds"'
expect "${BODY}" 'titled with the backup name'   'Nightly NAS'
expect "${BODY}" 'and the parsed result'         'Success'
expect "${BODY}" 'coloured green'                '"color":3066993'
expect "${BODY}" 'carrying the normalised duration' '4m 12s'
expect "${BODY}" 'human-readable sizes'          '919\.8 GiB'
expect "${BODY}" 'the sanitised destination'     's3://acme-offsite-backups/nas'
expect "${BODY}" 'the source paths'              '/source/documents, /source/photos'
expect "${BODY}" 'and the hostname in the footer' 'tank . Duplicati'
# The assertion this whole mod is judged on.
refute "${BODY}" 'no S3 secret key crossed the network' 'wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY'
refute "${BODY}" 'no access key id either'               'AKIAIOSFODNN7EXAMPLE'
refute "${BODY}" 'and no query string at all'            'auth-password'

#------------------------------------------------------------------------------
say "Scenario 2: a fatal backup is red, quotes the errors, and still exits 0"
start_stub dupsmoke/discord-ok
run_mod DUPLICATI__PARSED_RESULT=Fatal \
    DUPLICATI__RESULTFILE=/fixtures/error.json \
    'DUPLICATI__REMOTEURL=s3://acme-offsite-backups/nas' \
    'DISCORD_MENTION_ON_ERROR=<@&123456789012345678>'
BODY="$(bodies)"
dump "${BODY}"
eq 'still exits 0 -- a failed backup is for Duplicati to report, not this script' 0 "${MOD_RC}"
expect "${BODY}" 'coloured for Fatal'         '"color":10038562'
expect "${BODY}" 'the log block is fenced'    '```'
expect "${BODY}" 'and names the real failure' 'AWS Access Key Id'
expect "${BODY}" 'the role is mentioned in content, where Discord notifies' '"content":"<@&123456789012345678>"'

#------------------------------------------------------------------------------
say "Scenario 3: credentials quoted inside Duplicati's own error text"
# Stripping DUPLICATI__REMOTEURL is not enough on its own -- the exception
# messages carry the same secrets, and a different backend's on top.
start_stub dupsmoke/discord-ok
run_mod DUPLICATI__PARSED_RESULT=Error \
    DUPLICATI__RESULTFILE=/fixtures/credentials.json \
    "DUPLICATI__REMOTEURL=${CRED_URL}"
BODY="$(bodies)"
dump "${BODY}"
eq 'exits 0' 0 "${MOD_RC}"
refute "${BODY}" 'the S3 secret is not in the log block'   'wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY'
refute "${BODY}" 'nor is the ssh passphrase'               'hunter2SuperSecretPassphrase'
refute "${BODY}" 'nor any auth query parameter'            'auth-(username|password)='
expect "${BODY}" 'but the destination is still identifiable' 'acme-offsite-backups/nas'

#------------------------------------------------------------------------------
say "Scenario 4: the NO_JQ fallback sends a flat content message"
# Same container, jq removed. The notification degrades; it does not become
# invalid JSON, and it does not start leaking.
docker rm -f dup-mod >/dev/null 2>&1
start_stub dupsmoke/discord-ok
docker run --name dup-mod --network "${NET}" \
    -e DUPLICATI__EVENTNAME=AFTER -e DUPLICATI__OPERATIONNAME=Backup \
    -e DUPLICATI__PARSED_RESULT=Warning \
    -e "DUPLICATI__backup_name=Nightly NAS" \
    -e DUPLICATI__RESULTFILE=/fixtures/warnings.json \
    -e 'DUPLICATI__REMOTEURL=ssh://backupsvc:hunter2SuperSecretPassphrase@nas.example.internal/vol1' \
    -e DISCORD_HOSTNAME=tank \
    -e "DISCORD_WEBHOOK_URL=http://discord-stub:8080/api/webhooks/1234567890/aTokenThatIsNotReal" \
    --entrypoint bash "${RUNNER}" -c 'rm -f "$(command -v jq)"; bash /duplicati-discord.sh' \
    >"${WORK}/out" 2>"${WORK}/err"
MOD_RC=$?
BODY="$(bodies)"
dump "${BODY}"
eq 'exits 0 without jq' 0 "${MOD_RC}"
eq 'one request still arrived' 1 "$(request_count)"
expect "${BODY}" 'it is a flat content message' '"content"'
refute "${BODY}" 'with no embed'                '"embeds"'
expect "${BODY}" 'still carrying the result'    'Nightly NAS'
refute "${BODY}" 'and still no passphrase'      'hunter2SuperSecretPassphrase'
# Proves the pure-bash encoder produced something Discord could actually parse.
if printf '%s' "${BODY}" | docker run --rm -i "${RUNNER}" jq -e . >/dev/null 2>&1; then
    pass 'and the hand-built JSON parses'
else
    fail 'and the hand-built JSON parses' "not valid JSON: ${BODY}"
fi

#------------------------------------------------------------------------------
say "Scenario 5: filters keep quiet without touching the network"
start_stub dupsmoke/discord-ok
run_mod DUPLICATI__PARSED_RESULT=Success \
    DUPLICATI__RESULTFILE=/fixtures/success.json \
    'DUPLICATI__REMOTEURL=s3://bucket/path' \
    DISCORD_NOTIFY_ON=error
eq 'DISCORD_NOTIFY_ON=error: exits 0' 0 "${MOD_RC}"
eq 'and sends nothing at all'         0 "$(request_count)"

start_stub dupsmoke/discord-ok
run_mod DUPLICATI__OPERATIONNAME=Compact DUPLICATI__PARSED_RESULT=Success \
    DUPLICATI__RESULTFILE=/fixtures/success.json \
    'DUPLICATI__REMOTEURL=s3://bucket/path'
eq 'the default operation allowlist drops Compact' 0 "$(request_count)"

start_stub dupsmoke/discord-ok
run_mod DUPLICATI__EVENTNAME=BEFORE DUPLICATI__PARSED_RESULT=Success \
    DUPLICATI__RESULTFILE=/fixtures/success.json \
    'DUPLICATI__REMOTEURL=s3://bucket/path'
eq 'the BEFORE event sends nothing' 0 "$(request_count)"

#------------------------------------------------------------------------------
say "Scenario 6: the webhook can come from a file, the way a docker secret does"
start_stub dupsmoke/discord-ok
docker rm -f dup-mod >/dev/null 2>&1
docker run --name dup-mod --network "${NET}" \
    -e DUPLICATI__EVENTNAME=AFTER -e DUPLICATI__OPERATIONNAME=Backup \
    -e DUPLICATI__PARSED_RESULT=Success \
    -e DUPLICATI__RESULTFILE=/fixtures/success.json \
    -e 'DUPLICATI__REMOTEURL=s3://bucket/path' \
    -e DISCORD_WEBHOOK_URL_FILE=/run/secrets/discord_webhook \
    --entrypoint bash "${RUNNER}" -c '
        mkdir -p /run/secrets
        # With a trailing newline on purpose: that is how every secrets manager
        # writes one, and an untrimmed newline makes the URL unusable.
        printf "http://discord-stub:8080/api/webhooks/1234567890/aTokenThatIsNotReal\n" >/run/secrets/discord_webhook
        bash /duplicati-discord.sh' >/dev/null 2>&1
eq 'a webhook read from a file works, trailing newline and all' 1 "$(request_count)"

#------------------------------------------------------------------------------
say "Scenario 7: HTTP 429 is retried exactly once"
start_stub dupsmoke/discord-429
run_mod DUPLICATI__PARSED_RESULT=Success \
    DUPLICATI__RESULTFILE=/fixtures/success.json \
    'DUPLICATI__REMOTEURL=s3://bucket/path'
dump "${MODLOG}"
eq 'a permanent 429 still exits 0'  0 "${MOD_RC}"
eq 'two attempts, not one and not a loop' 2 "$(request_count)"
expect "${MODLOG}" 'and it says the send failed' 'HTTP 429'

#------------------------------------------------------------------------------
say "Scenario 8: a deleted webhook is explained, not swallowed"
start_stub dupsmoke/discord-404
run_mod DUPLICATI__PARSED_RESULT=Success \
    DUPLICATI__RESULTFILE=/fixtures/success.json \
    'DUPLICATI__REMOTEURL=s3://bucket/path'
dump "${MODLOG}"
eq 'a 404 still exits 0' 0 "${MOD_RC}"
expect "${MODLOG}" 'names the status'      'HTTP 404'
expect "${MODLOG}" 'and says what to fix'  'webhook URL is wrong'

#------------------------------------------------------------------------------
say "Scenario 9: an unreachable webhook host cannot fail the backup"
docker rm -f dup-hook >/dev/null 2>&1
run_mod DUPLICATI__PARSED_RESULT=Success \
    DUPLICATI__RESULTFILE=/fixtures/success.json \
    'DUPLICATI__REMOTEURL=s3://bucket/path' \
    DISCORD_TIMEOUT=3
dump "${MODLOG}"
eq 'nothing listening: still exits 0' 0 "${MOD_RC}"
expect "${MODLOG}" 'and reports the curl failure' 'curl failed'

#------------------------------------------------------------------------------
say "Scenario 10: DISCORD_TEST_ON_START, through the real init oneshot"
# Drives root/etc/s6-overlay/s6-rc.d/init-mod-...-test/run, not a stand-in, so
# the truthy check and the exit-0 guarantee are the ones that ship.
start_stub dupsmoke/discord-ok
docker rm -f dup-mod >/dev/null 2>&1
docker run --name dup-mod --network "${NET}" \
    -e DISCORD_TEST_ON_START=true \
    -e DISCORD_HOSTNAME=tank \
    -e "DISCORD_WEBHOOK_URL=http://discord-stub:8080/api/webhooks/1234567890/aTokenThatIsNotReal" \
    "${RUNNER}" bash /test-oneshot.sh >"${WORK}/out" 2>"${WORK}/err"
MOD_RC=$?
MODLOG="$(cat "${WORK}/out" "${WORK}/err" 2>/dev/null)"
BODY="$(bodies)"
dump "${MODLOG}"
eq 'the oneshot exits 0, so it cannot block container startup' 0 "${MOD_RC}"
eq 'one test message arrived' 1 "$(request_count)"
expect "${MODLOG}" 'the log says a test is being sent' 'sending a test notification'
expect "${MODLOG}" 'and confirms it went'              'test notification sent'
expect "${BODY}" 'the body is an embed'                '"embeds"'
expect "${BODY}" 'titled as a test'                    'Test notification'
expect "${BODY}" 'in its own colour, not a result one' '"color":5793266'
expect "${BODY}" 'naming the option to paste'          'run-script-after=/usr/local/bin/duplicati-discord.sh'
expect "${BODY}" 'and how to turn it off'              'DISCORD_TEST_ON_START'

say "Scenario 10b: the whole truthy set, in both directions"
# The negative list was thorough and the positive one was not, which is how a
# truthy value that silently does nothing ships. Each case restarts the stub, so
# a leak names the value that leaked instead of failing every case after it.
HOOK="http://discord-stub:8080/api/webhooks/1234567890/aTokenThatIsNotReal"
run_oneshot() { # run_oneshot [DISCORD_TEST_ON_START value, or nothing]
    start_stub dupsmoke/discord-ok
    docker rm -f dup-mod >/dev/null 2>&1
    local -a e=(-e "DISCORD_WEBHOOK_URL=${HOOK}")
    (($#)) && e+=(-e "DISCORD_TEST_ON_START=$1")
    docker run --name dup-mod --network "${NET}" "${e[@]}" \
        "${RUNNER}" bash /test-oneshot.sh >/dev/null 2>&1
}
run_oneshot
eq 'unset: sends nothing' 0 "$(request_count)"
for v in false 0 no off disabled ''; do
    run_oneshot "${v}"
    eq "DISCORD_TEST_ON_START='${v}' sends nothing" 0 "$(request_count)"
done
for v in true 1 yes on enable enabled TRUE True; do
    run_oneshot "${v}"
    eq "DISCORD_TEST_ON_START='${v}' sends" 1 "$(request_count)"
done
# No stub at all: the oneshot must still come back clean.
docker rm -f dup-hook >/dev/null 2>&1
docker rm -f dup-mod >/dev/null 2>&1
docker run --name dup-mod --network "${NET}" \
    -e DISCORD_TEST_ON_START=true -e DISCORD_TIMEOUT=3 \
    -e "DISCORD_WEBHOOK_URL=http://discord-stub:8080/api/webhooks/1/x" \
    "${RUNNER}" bash /test-oneshot.sh >/dev/null 2>&1
eq 'an unreachable webhook still exits 0' 0 "$?"

#------------------------------------------------------------------------------
printf '\n'
if ((FAILED)); then
    printf '\033[1;31m%d smoke assertion(s) FAILED\033[0m\n' "${FAILED}"
    exit 1
fi
printf '\033[1;32mAll smoke assertions passed\033[0m\n'
