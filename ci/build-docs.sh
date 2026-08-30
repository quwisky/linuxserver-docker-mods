#!/usr/bin/env bash
# Assemble docs/ for MkDocs from the READMEs already in the repo.
#
#   ci/build-docs.sh
#
# The READMEs stay the single source of truth: they are what GitHub renders, what
# the GHCR package pages show, and what someone reads in a clone. Maintaining a
# second copy under docs/ would drift within a week, so generated pages stay
# git-ignored. The tracked docs/agents/ configuration is preserved but excluded
# from the public site.
#
# What this has to fix up is links. A relative link that works from
# mods/plex/vaapi-amdgpu-mod/README.md does not work from the page it becomes,
# so links to files that are not themselves pages are rewritten to point at
# GitHub, and links between mods are rewritten to point at each other.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

MODS_DIR="${MODS_DIR:-mods}"
OUT="${OUT:-docs}"
# Where non-page links should point. Overridable so a fork does not have to edit
# the script.
REPO_URL="${REPO_URL:-https://github.com/quwisky/linuxserver-docker-mods}"
BRANCH="${DOCS_SOURCE_BRANCH:-master}"
BLOB="${REPO_URL}/blob/${BRANCH}"

# OUT is configurable for local previews, but it is also recursively replaced.
# Keep that deletion inside this checkout and away from source directories: a
# typo such as OUT=mods must fail before it destroys the source tree.
OUT_ABS="$(realpath -m -- "${OUT}")"
case "${OUT_ABS}" in
    "${REPO}"/*) ;;
    *)
        echo "refusing to replace docs output outside the repository: ${OUT_ABS}" >&2
        exit 1
        ;;
esac
OUT_REL="${OUT_ABS#"${REPO}"/}"
MARKER=.generated-by-build-docs
# docs/ is the established generated target and predates the marker. Any other
# existing path must prove that an earlier successful invocation created it;
# otherwise OUT=mods (or another source directory) is a destructive typo.
if [[ -e ${OUT_ABS} && ${OUT_ABS} != "${REPO}/docs" && ! -f ${OUT_ABS}/${MARKER} ]]; then
    echo "refusing to replace an existing directory not created by build-docs: ${OUT_REL}" >&2
    exit 1
fi

if [[ ${OUT_ABS} == "${REPO}/docs" && -d ${OUT_ABS}/agents ]]; then
    find "${OUT_ABS}" -mindepth 1 -maxdepth 1 ! -name agents -exec rm -rf -- {} +
else
    rm -rf -- "${OUT_ABS}"
fi
mkdir -p "${OUT_ABS}"
touch "${OUT_ABS}/${MARKER}"
# Use the canonical path from here on, so a symlink or `..` component cannot
# make the validated target differ from the directory subsequently written.
OUT="${OUT_ABS}"

# --- root README -> the site's home page ---------------------------------
cp README.md "${OUT}/index.md"

# --- changelog, if there is one ------------------------------------------
if [[ -f CHANGELOG.md ]]; then
    cp CHANGELOG.md "${OUT}/changelog.md"
fi

# --- one page per mod, mirroring the mods/<app>/<mod> shape --------------
count=0
for d in "${MODS_DIR}"/*/*/; do
    [[ -f "${d}Dockerfile" ]] || continue
    mod="$(basename "${d%/}")"
    app="$(basename "$(dirname "${d%/}")")"
    [[ -f "${d}README.md" ]] || {
        echo "::error::${d} has no README.md to publish" >&2
        exit 1
    }
    mkdir -p "${OUT}/mods/${app}"
    cp "${d}README.md" "${OUT}/mods/${app}/${mod}.md"
    [[ -f "${d}CHANGELOG.md" ]] || {
        echo "::error::${d} has no package CHANGELOG.md to publish" >&2
        exit 1
    }
    cp "${d}CHANGELOG.md" "${OUT}/mods/${app}/${mod}-changelog.md"
    count=$((count + 1))
done

if ((count == 0)); then
    echo "::error::no mods found under ${MODS_DIR}/, refusing to publish an empty site" >&2
    exit 1
fi

# --- link fix-ups ---------------------------------------------------------
# index.md: the mod table links to directories; those are pages here.
#   ](mods/plex/vaapi-amdgpu-mod/)  ->  ](mods/plex/vaapi-amdgpu-mod.md)
sed -i.bak -E 's#\]\('"${MODS_DIR}"'/([a-z0-9-]+)/([a-z0-9-]+)/\)#]('"${MODS_DIR}"'/\1/\2.md)#g' "${OUT}/index.md"

# Anything pointing into .github/ is a file, not a page: send it to GitHub.
# Mod pages sit two levels down, so they use ../../../; index.md uses none.
sed -i.bak -E 's#\]\((\.\./)*(\.github/[^)]+)\)#]('"${BLOB}"'/\2)#g' \
    "${OUT}/index.md" "${OUT}"/mods/*/*.md

# Same for links into ci/ or template/, which are directories of source.
sed -i.bak -E 's#\]\((\.\./)*((ci|template)/[^)]*)\)#]('"${BLOB}"'/\2)#g' \
    "${OUT}/index.md" "${OUT}"/mods/*/*.md

# A source README is at mods/<app>/<mod>/README.md, so a link to another mod is
# ../../<app>/<mod>/. Its generated page is one level up from the current page.
# Keep source links correct on GitHub and translate them for the site here.
sed -i.bak -E 's#\]\(\.\./\.\./([a-z0-9-]+)/([a-z0-9-]+)/\)#](../\1/\2.md)#g' \
    "${OUT}"/mods/*/*.md

# Root links to CHANGELOG.md resolve to the repository-wide page.
sed -i.bak -E 's@\]\(CHANGELOG\.md(#[^)]*)?\)@](changelog.md\1)@g' "${OUT}/index.md"

# A mod README's sibling CHANGELOG.md becomes a sibling generated page.
for page in "${OUT}"/mods/*/*.md; do
    [[ ${page} == *-changelog.md ]] && continue
    mod="$(basename "${page}" .md)"
    sed -i.bak -E 's@\]\(CHANGELOG\.md(#[^)]*)?\)@]('"${mod}"'-changelog.md\1)@g' "${page}"
done

# CHANGELOG.md links to README.md by name, which is index.md on the site.
if [[ -f "${OUT}/changelog.md" ]]; then
    # `@` as the delimiter: the pattern itself contains `#`, for the anchor.
    sed -i.bak -E 's@\]\(README\.md(#[^)]*)?\)@](index.md\1)@g' "${OUT}/changelog.md"
fi

find "${OUT}" -name '*.bak' -delete

echo "**** ${OUT}/ built: ${count} mod page(s) ****"
find "${OUT}" -name '*.md' | sort | sed 's/^/  /'
