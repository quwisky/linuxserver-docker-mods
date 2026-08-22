# syntax=docker/dockerfile:1

# A mod is a filesystem overlay, nothing more: FROM scratch plus a single COPY
# produces exactly one layer, which is all /docker-mods ever pulls (it reads
# .layers[0] of the manifest and ignores the rest).
#
# The build context is the REPO ROOT, not this directory, so that shared/ is
# reachable for mods that use it. That is why the path below is repo-relative.
#
# If you need to ship a binary, download or compile it in a build stage and
# consolidate into ONE final COPY -- never add a second COPY or RUN to the
# scratch stage. The same trick lets a mod pull in shared/, see
# mods/qbittorrent/gluetun-portforward-mod/Dockerfile.

FROM scratch

LABEL maintainer="quwisky"

# copy local files
COPY mods/duplicati/discord-notify-mod/root/ /
