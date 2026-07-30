# syntax=docker/dockerfile:1

# A mod is a filesystem overlay, nothing more: FROM scratch plus a single COPY
# produces exactly one layer, which is all /docker-mods ever pulls (it reads
# .layers[0] of the manifest and ignores the rest).
#
# If you need to ship a binary, download or compile it in a build stage and
# consolidate into ONE final COPY -- never add a second COPY or RUN to the
# scratch stage.

FROM scratch

LABEL maintainer="quwisky"

# copy local files
COPY root/ /
