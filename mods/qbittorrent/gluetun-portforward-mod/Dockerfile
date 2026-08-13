# syntax=docker/dockerfile:1

# A mod is a filesystem overlay, nothing more, and it must be exactly ONE layer:
# /docker-mods reads .layers[0] of the manifest and ignores the rest.
#
# The build context is the REPO ROOT, not this directory, so that shared/ is
# reachable -- see the root README. That is also why the paths below are
# repo-relative.
#
# Two COPYs are needed to assemble the overlay, which would be two layers. So
# they happen in a scratch *assembly* stage, and the final stage takes the
# result in a single COPY --from. One layer, two sources.

FROM scratch AS assemble
COPY mods/qbittorrent/gluetun-portforward-mod/root/ /
COPY shared/mod-gluetun-portforward/ /usr/local/lib/mod-gluetun-portforward/

FROM scratch

LABEL maintainer="quwisky"

COPY --from=assemble / /
