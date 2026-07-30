# Changelog

Notable changes to this repository and to the mods it publishes.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries that affect a single mod are prefixed with that mod's id, since each mod
is published as its own GHCR package and people generally care about one of them.

This file is written by hand rather than generated from commit messages. History
here is squashed, so a generator would have almost nothing to read — and the
useful unit of change is "what does this mean for someone pulling the image",
which a commit subject rarely captures.

There are no version tags. Mods publish as `:latest` from `master` and `:nightly`
from `develop`, with immutable pins alongside, so releases are dated rather than
numbered. See [Release channels](README.md#release-channels).

## [Unreleased]

### Fixed

- Single-platform mods published a manifest `/docker-mods` cannot read, so they
  never loaded. It fetches the manifest sending only
  `application/vnd.docker.distribution.manifest.v2+json` and
  `application/vnd.oci.image.index.v1+json`; a multi-platform build yields an OCI
  index (accepted), but a single-platform build yields a bare OCI image manifest
  (not accepted), and the registry answers `404 MANIFEST_UNKNOWN`. The mod then
  falls back to its cache, so on a fresh container nothing happens and the log
  says only `digest could not be fetched`.

  This affected **plex-vaapi-amdgpu-mod**, which is `linux/amd64` only.
  Single-platform mods now publish Docker media types, and every publish asserts
  the manifest is readable with those exact Accept headers, so it cannot regress
  silently. **Republish any single-platform mod to pick this up.**

### Added

- **qbittorrent-gluetun-portforward-mod** — keeps qBittorrent's listening port in
  sync with the port gluetun forwards, through the WebUI API, live and with no
  restart. Also forces `random_port` and `upnp` off, since a forwarded port is
  pointless if the client then picks its own.

  Beyond mirroring the Plex mod's gluetun handling, it deals with a
  qBittorrent-specific problem: the client does not reliably re-open its
  listening socket after the tunnel drops, so it can hold the right port number
  and still not be listening on it. When gluetun reports no port, the next port
  is written **even if unchanged**, which nudges qBittorrent into re-binding.

  Authentication is either qBittorrent's localhost bypass or a permanent WebUI
  password. The temporary `admin` password the image prints on start is
  regenerated every restart, so it cannot be used; with neither configured the
  mod reports the 403 once and names both fixes.

## [2026-07-30]

### Added

- **plex-gluetun-portforward-mod** — keeps Plex's public remote-access port in
  sync with the port [gluetun](https://github.com/qdm12/gluetun) forwards, via
  Plex's `/:/prefs` API, live and with no restart. Handles every gluetun
  response shape across releases, treats "no forwarded port" as a normal state
  that leaves Plex untouched, and bounds writes four ways against Plex's
  rate limiting on published mapping state.
- **plex-vaapi-amdgpu-mod** — bundles current Mesa and libva from Alpine edge so
  AMD GPUs, including RDNA4/gfx1151, can hardware transcode in Plex. Migrated
  from its own repository; the GHCR package name is unchanged, so existing
  `DOCKER_MODS` values keep working. `linux/amd64` only.
- One workflow per mod, each gated on its own directory, so touching one mod
  never runs another's tests. Shared logic lives once in a reusable workflow.
- Nightly builds from `develop`, published as `:nightly`. The pin is the git
  tree hash of the mod's directory, so an unchanged night resolves to a tag that
  already exists and the publish is skipped while the tests still run.
- **plex-vaapi-amdgpu-mod** — a monthly rebuild of `master`, carried over from
  its standalone repo, so `:latest` keeps picking up new Mesa rather than
  freezing between pushes.
- Custom-tag publishing: a manual run with the **tag** field filled in builds any
  branch and publishes it under that tag alone, without touching `:latest` or
  `:nightly`.
- `ci/new-mod.sh` scaffolds a mod and its workflow from `template/`;
  `ci/check-mod-workflows.sh` and `ci/check-mod-layout.sh` fail the build on the
  ways a mod can silently never be built.
- A [documentation site](https://quwisky.github.io/linuxserver-docker-mods/)
  built with MkDocs Material and deployed to GitHub Pages, generated from the
  READMEs so there is no second copy to drift.

### Notes

- Each mod is its own GHCR package named `<app>-<mod>`, composed from the two
  directory levels of `mods/<app>/<mod>`. Packages are private when first
  created — set visibility to public once per mod, or `/docker-mods` gets a 401
  pulling the manifest.
- Licensed under MIT.

[Unreleased]: https://github.com/quwisky/linuxserver-docker-mods/compare/master...develop
