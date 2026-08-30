#!/usr/bin/env bash
# Verify a GHCR image exactly as LinuxServer's /docker-mods loader reads it.
set -Eeuo pipefail

usage() {
    printf 'usage: GH_USER=<user> GH_PASS=<token> ci/verify-published-mod.sh ghcr.io/<owner>/<package>:<tag>[@sha256:<digest>]\n' >&2
    exit 2
}

[[ $# -eq 1 ]] || usage
REFERENCE="$1"
: "${GH_USER:?GH_USER is required}"
: "${GH_PASS:?GH_PASS is required}"
[[ ${REFERENCE} == ghcr.io/*:* ]] || usage

ref="${REFERENCE#ghcr.io/}"
if [[ ${ref} == *@sha256:* ]]; then
    repo="${ref%%@*}"
    selector="${ref#*@}"
else
    repo="${ref%%:*}"
    selector="${ref#*:}"
fi
token="$(curl --fail --silent --show-error -u "${GH_USER}:${GH_PASS}" \
    "https://ghcr.io/token?scope=repository:${repo}:pull&service=ghcr.io" | jq -er .token)"

request_manifest() {
    local wanted="$1"
    local child="${2:-false}"
    local -a headers=(
        --header 'Accept: application/vnd.docker.distribution.manifest.v2+json'
        --header 'Accept: application/vnd.oci.image.index.v1+json'
    )
    if [[ ${child} == true ]]; then
        headers+=(--header 'Accept: application/vnd.oci.image.manifest.v1+json')
    fi
    curl --silent --show-error --write-out '\n%{http_code}' \
        "${headers[@]}" \
        --header "Authorization: Bearer ${token}" \
        "https://ghcr.io/v2/${repo}/manifests/${wanted}"
}

body="$(request_manifest "${selector}")"
code="${body##*$'\n'}"
json="${body%$'\n'*}"
if [[ ${code} != 200 ]]; then
    printf '::error title=Mod is unreadable::%s returned HTTP %s.\n%s\n' "${REFERENCE}" "${code}" "${json}" >&2
    exit 1
fi

if jq -e '.layers | type == "array"' >/dev/null 2>&1 <<<"${json}"; then
    layers="$(jq -r '.layers | length' <<<"${json}")"
    [[ ${layers} == 1 ]] || {
        printf '::error::%s has %s layers; /docker-mods extracts only the first.\n' "${REFERENCE}" "${layers}" >&2
        exit 1
    }
    printf 'single manifest: 1 layer (%s)\n' "$(jq -r '.layers[0].digest' <<<"${json}")"
else
    mapfile -t manifests < <(jq -r \
        '.manifests[] | select(.platform.architecture != "unknown") | [(.platform.os + "/" + .platform.architecture), .digest] | @tsv' \
        <<<"${json}")
    ((${#manifests[@]} > 0)) || {
        printf '::error::%s index has no usable architecture entry.\n' "${REFERENCE}" >&2
        exit 1
    }
    for entry in "${manifests[@]}"; do
        platform="${entry%%$'\t'*}"
        digest="${entry#*$'\t'}"
        child="$(request_manifest "${digest}" true)"
        child_code="${child##*$'\n'}"
        child_json="${child%$'\n'*}"
        [[ ${child_code} == 200 ]] || {
            printf '::error::%s %s returned HTTP %s.\n' "${REFERENCE}" "${platform}" "${child_code}" >&2
            exit 1
        }
        layers="$(jq -r '.layers | length' <<<"${child_json}")"
        [[ ${layers} == 1 ]] || {
            printf '::error::%s %s has %s layers.\n' "${REFERENCE}" "${platform}" "${layers}" >&2
            exit 1
        }
        printf '%s %s: 1 layer\n' "${platform}" "${digest}"
    done
fi
printf '**** %s is readable by /docker-mods ****\n' "${REFERENCE}"
