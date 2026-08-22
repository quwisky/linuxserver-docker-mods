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

### Added

- **duplicati-discord-notify-mod** — a new mod for `linuxserver/duplicati`,
  published as `ghcr.io/quwisky/duplicati-discord-notify-mod`. Pulling it gets
  you a colour-coded Discord embed after every Duplicati operation instead of
  Duplicati's own choice of an email or a raw JSON POST — green for success,
  amber for warnings, red for errors, a skull for fatal, with the backup name in
  the title, the statistics as fields, and the actual error and warning lines
  quoted in a fenced code block when there are any.

  **The destination is sanitised before it is ever displayed.**
  `DUPLICATI__REMOTEURL` carries the backend's credentials inline — S3 secret
  keys, B2 application keys, OAuth ids, ssh passphrases — and Duplicati quotes
  that URL back at you inside its own exception messages. A webhook message is a
  permanent record in a chat history, so the query string and any userinfo are
  stripped from the destination, and a second pattern-based pass covers every
  log line the mod quotes, including credentials belonging to some other backend
  that an inner exception happened to name. Both passes have tests, in the unit
  suite and end to end against a stub that logs what actually crossed the wire.

  Neither the webhook URL nor the payload ever reaches the process table: the
  URL is handed to `curl` through `--config` on a pipe, the body on stdin. The
  token in a webhook URL is the credential, and argv is readable from
  `/proc/<pid>/cmdline` by anything running as the same user.

  **It cannot fail your backup.** Duplicati treats a non-zero exit from
  `--run-script-after` as the operation having failed, and says so everywhere
  else you have notifications configured. The script therefore exits 0
  unconditionally; a dead webhook, a 404, a rate limit and a DNS failure each
  produce a line on stderr and nothing more. The smoke test asserts that against
  all four.

  Without `jq` it degrades rather than breaks: the payload becomes a flat
  `content` message assembled by a pure-bash JSON encoder — no embed, no colour,
  but valid JSON and still redacted. CI runs the whole unit suite a second time
  with `jq` masked to keep that path honest.

  **One manual step is still required, and no mod can remove it.** Duplicati
  keeps its default options in `Duplicati-server.sqlite`, so
  `--run-script-after=/usr/local/bin/duplicati-discord.sh` has to be added once
  under **Settings → Default options** in the web UI. The mod prints the exact
  line into the container log at every start.

  Configuration is `DISCORD_WEBHOOK_URL` (or `_FILE`, or
  `/config/discord-webhook.url`), plus filters for severity and operation and
  an optional role mention on errors only; the mod's own README has the full
  table. `DISCORD_TEST_ON_START=true` posts one message at container start, in
  its own colour so it cannot be mistaken for a backup result, to prove the
  webhook works without waiting for a backup to find out.

- **A nightly documentation channel.** The site now publishes twice: the stable
  docs from `master` at the usual URL, describing the `:latest` images, and the
  nightly docs from `develop` under
  [`/nightly/`](https://quwisky.github.io/linuxserver-docker-mods/nightly/),
  describing `:nightly`. Every page of both sites carries a channel dropdown in
  the header with the current one ticked, the nightly site adds a banner, and
  its "view on GitHub" links point at `develop`.

  Reading instructions from `develop` while running `:latest` was previously
  impossible to notice — the two were the same site.

  GitHub Pages allows one deployment per repository, so the channels are not
  published independently: each run rebuilds both branches into a single tree
  and uploads one artifact. A push to either branch therefore refreshes both,
  and `docs.yml` has to be present on both for that to keep working. A
  `develop` that does not build costs only `/nightly/`, which is replaced by a
  page saying so; the stable site is published regardless.

## [2026-08-22]

### Added

- **plex-gluetun-portforward-mod**, **qbittorrent-gluetun-portforward-mod** — an
  opt-in watchdog that can **halt its own container**, to recover from a gluetun
  restart. **Off by default**: nothing changes until
  `GLUETUN_PF_NETNS_WATCHDOG=true` is set, and containers already pulling
  `:latest` behave byte-identically until then.

  `network_mode: service:gluetun` joins gluetun's network namespace by container
  ID. When gluetun *restarts* — not merely reconnects — that namespace is
  destroyed, and Docker never re-attaches the app container. It is left stranded
  with only `lo`: up, healthy-looking, unreachable, and unable to route out until
  something restarts it. The watchdog detects this from the inside and exits
  PID 1 so the restart policy brings the container back attached correctly.

  The signal is the absence of any non-loopback interface in `/sys/class/net`,
  which is what makes it safe to act on: a VPN reconnect tears down `tun0` but
  leaves `eth0`, so a reconnect cannot be mistaken for an orphaning. Reachability
  of gluetun's control server is deliberately not used, since it cannot tell the
  two apart. The scan is pure bash against `/sys` — no new packages.

  It also gives up. Halting is only a recovery if the container comes back, and
  when it does not — no `restart:` policy, or a shutdown that cannot complete —
  s6 restarts the service and the cycle would repeat forever. After
  `_MAX_HALTS` attempts (default 3) the watchdog switches itself off, says why,
  and leaves the port sync running. The count is per container start rather than
  cumulative, so halts that work never use the budget up; only failed ones do.
  Keeping that count means writing one small file under `/run`, which is the
  only thing either mod writes anywhere — the count has to outlive the halt,
  and the halt ends the process.

  `restart: unless-stopped` (or `on-failure`) is required; halting is only half
  the mechanism. The halt is graceful, so s6 runs the shutdown sequence and the
  application closes its files properly — qBittorrent writes its fastresume data,
  Plex closes its library database — which is the advantage over an external
  `docker kill`. Tunable via `_STRIKES`, `_GRACE`, `_EXIT_CODE`, and a `_DRY_RUN`
  that logs the decision without acting on it. Both mods use the same variable
  names, so running both behind one gluetun means one set of values.

  Picking this up needs `docker compose up -d --force-recreate`, since a mod is
  only re-applied when a container is recreated, not restarted.

- A `shared/` directory for code more than one mod overlays, so the netns
  watchdog exists once rather than as a copy per mod. Each mod's **build context
  is now the repo root** instead of its own directory, which is what makes
  `shared/` reachable; the single-layer rule is unchanged, because a mod that
  needs two sources assembles them in a `FROM scratch` stage and the final stage
  takes the result in one `COPY --from`. A mod that shares nothing keeps a single
  plain `COPY`.

  Two things had to follow, and both are enforced rather than documented:

  - `ci/check-shared-files.sh` fails the build when a mod copies `shared/<name>`
    without carrying `'shared/<name>/**'` in its workflow's `paths:` filter. Per-mod
    workflows are gated on their own directory, so without that filter a change to
    shared code would alter the mod's image without running its tests or its
    build — the same silent failure as a mod having no workflow at all. It also
    reports shared directories nothing uses, and still refuses to let two mods
    ship different content at the same container path.
  - `ci/mod-inputs.sh` derives the nightly content hash from the mod directory
    *plus* every `shared/` directory its Dockerfile copies, reading the list from
    the Dockerfile so it cannot drift. The old pin hashed the mod directory alone,
    which would have made a shared-code change produce a different image under a
    pin that already existed — and the nightly publish is deduped on exactly that,
    so it would have been skipped silently, every night.

  The per-mod `.dockerignore` files are gone, replaced by one at the repo root.

## [2026-07-30]

### Added

- **plex-gluetun-portforward-mod** — keeps Plex's public remote-access port in
  sync with the port [gluetun](https://github.com/qdm12/gluetun) forwards, via
  Plex's `/:/prefs` API, live and with no restart. Handles every gluetun
  response shape across releases, treats "no forwarded port" as a normal state
  that leaves Plex untouched, and bounds writes four ways against Plex's rate
  limiting on published mapping state.
- **plex-vaapi-amdgpu-mod** — bundles current Mesa and libva from Alpine edge so
  AMD GPUs, including RDNA4/gfx1151, can hardware transcode in Plex. Migrated
  from its own repository; the GHCR package name is unchanged, so existing
  `DOCKER_MODS` values keep working. `linux/amd64` only, and rebuilt monthly from
  `master` so `:latest` keeps picking up new Mesa rather than freezing between
  pushes.
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

- One workflow per mod, each gated on its own directory, so touching one mod
  never runs another's tests. Shared logic lives once in a reusable workflow.
- Nightly builds from `develop`, published as `:nightly`. The pin is the git tree
  hash of the mod's directory, so an unchanged night resolves to a tag that
  already exists and the publish is skipped while the tests still run.
- Custom-tag publishing: a manual run with the **tag** field filled in builds any
  branch and publishes it under that tag alone, without touching `:latest` or
  `:nightly`.
- `ci/new-mod.sh` scaffolds a mod and its workflow from `template/`;
  `ci/check-mod-workflows.sh` and `ci/check-mod-layout.sh` fail the build on the
  ways a mod can silently never be built.
- A [documentation site](https://quwisky.github.io/linuxserver-docker-mods/)
  built with MkDocs Material and deployed to GitHub Pages, generated from the
  READMEs so there is no second copy to drift.
- A Dependabot config for `github-actions`, grouped into one monthly PR. A pinned
  major keeps working long after the Node runtime it declares is deprecated, and
  the only signal is a warning buried in a run log.

### Changed

- All GitHub Actions moved to majors that declare Node 24, since the runners now
  warn that Node 20 is deprecated: `checkout` v4→v7, `setup-python` v5→v7,
  `upload-pages-artifact` v3→v5, `deploy-pages` v4→v5, the three `docker/setup-*`
  and `login` actions v3→v4, and `build-push-action` v6→v7. Every input this repo
  passes was checked against the new majors first.

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
  silently.

### Notes

- Each mod is its own GHCR package named `<app>-<mod>`, composed from the two
  directory levels of `mods/<app>/<mod>`. GHCR creates a new package private, and
  `/docker-mods` cannot pull a private package — it gets a 401 on the manifest.
- Licensed under MIT.

[Unreleased]: https://github.com/quwisky/linuxserver-docker-mods/compare/master...develop
