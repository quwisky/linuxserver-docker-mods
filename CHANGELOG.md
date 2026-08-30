# Changelog

Notable changes to this repository and to the mods it publishes.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries that affect a single mod are prefixed with that mod's id, since each mod
is published as its own GHCR package and people generally care about one of them.

This file now records repository-wide history. Independently versioned package
history lives beside each mod and is generated from reviewed change fragments.

## [Unreleased]

### Added

- Independent SemVer releases for every mod, with package-scoped Git tags,
  GitHub Releases, exact/minor/major GHCR aliases, signed provenance, SBOMs, and
  digest-preserving promotion from a verified immutable candidate.
- A repository-native release planner using explicit JSON change fragments,
  automatic shared-input fan-out, one rolling combined release PR, resumable
  partial releases, and package-local version/changelog files.
- Constrained `test-<commit>` publishing, emergency `latest` rollback, bounded
  event-driven registry retention, Renovate base-digest maintenance, and a
  weekly shipped-artifact probe for VAAPI runtime updates.
- A dry-run-first cutover workflow that verifies all replacement releases before
  deleting legacy nightly package versions, `develop`, and its Pages policy.

### Changed

- Replaced per-mod callers and ambiguous duplicate checks with one affected-mod
  matrix and the stable `CI / required` branch-protection gate.
- `master` is the only long-lived branch. Verified unreleased work publishes as
  `:edge`; stable installs should use the current major tag such as `:1`.
- Documentation is built once from `master`; the nightly site, channel selector,
  banner, and dual-branch deployment logic are removed.

### Fixed

- Pull-request validation is isolated from the master-only publisher and no
  longer inherits repository secrets. Test publishing loads only from the
  default branch, uses untrusted refs solely as credential-free source
  contexts, and keeps verification tooling pinned to trusted `master`.
- Repository tooling now refuses to replace existing non-generated or
  out-of-repository paths during documentation generation, preserves template
  file modes even under a restrictive umask, verifies every architecture below
  a published image index, and omits the nonexistent immutable pin from
  custom-tag build summaries.
- **plex-vaapi-amdgpu-mod** — document host numeric DRM group IDs in the Compose
  example. Container-local `video` and `render` names can map to different GIDs
  and leave Plex unable to open a mounted render node.
- **duplicati-discord-notify-mod** — consistently document that failures and
  debug payloads go to stdout, as required to avoid Duplicati script warnings.
- **plex-vaapi-amdgpu-mod** — create and repair Plex cache directories as the
  configured application user. On a fresh `/config`, the root-run initializer
  previously created `Plex Media Server` as `root:root`, causing Plex to refuse
  to start for ordinary `PUID`/`PGID` deployments.
- Correct local build and lint commands, cross-mod documentation links, and the
  description of shared inputs in nightly content hashes.

- **duplicati-discord-notify-mod sent nothing at all.** Its script carried
  `#!/usr/bin/with-contenv bash`, and `with-contenv` *replaces* the environment
  with the container's — discarding every `DUPLICATI__` variable Duplicati
  exports, which is the entire input the mod reads. It saw an empty event name
  on every operation and returned without sending. The script now uses a plain
  shebang; it still receives the container's `DISCORD_` variables, because
  Duplicati is itself started under `with-contenv` and children inherit.

- **...and made every backup log a warning while doing it.** Duplicati raises
  `RunScript-StdErrorNotEmpty` for any output a hook puts on stderr, so the
  mod's own diagnostics — and anything `curl` printed — decorated the operation
  with a warning it had not earned. All output now goes to stdout.

  Both were reported from a running container, in one log line. Neither was
  reachable from the test suite: sourcing the script never runs its shebang, and
  the smoke harness's `with-contenv` stand-in passed the environment through
  instead of replacing it. Both are now covered, and the stand-in was corrected
  to behave like the real one.

### Changed

- **`:nightly` is now published on every push to `develop`**, not only by the
  nightly cron. `:nightly` previously meant "develop as of last night", which is
  a confusing thing to hand someone who has just merged a fix and wants to try
  it; it now means what it says. The cron still runs — it is what re-tests every
  mod against current base images — and the content-addressed pin still skips a
  publish when nothing changed, so a push that only touched shared CI does not
  churn every mod's `:nightly`.

### Added

- **universal-gluetun-netns-watchdog-mod** — a standalone version of the
  fail-safe network-namespace watchdog already shared by the Plex and
  qBittorrent Gluetun port-forward mods. It works with any current LinuxServer
  container using `network_mode: service:gluetun` or
  `network_mode: container:gluetun`.

  When Gluetun restarts, Docker can leave an attached application running in
  the destroyed namespace with only `lo`, unable to route out and unreachable
  through the ports now published on Gluetun's replacement namespace. After a
  startup grace period and four consecutive scans with no non-loopback
  interface, this mod gracefully halts the application container so its normal
  restart policy brings it back attached correctly. A VPN reconnect leaves
  `eth0` present and therefore does not trigger it.

  The standalone interface is `GLUETUN_NETNS_WATCHDOG_*`, isolated from the
  `GLUETUN_PF_*` variables used by the port-forward mods. It retains the shared
  helper's fail-open `/sys` handling, dry-run mode, configurable strike and
  grace thresholds, non-zero exit status, bounded failed-halt attempts, and
  graceful s6 shutdown. It installs no packages and needs no Docker socket.
  Recovery requires `restart: unless-stopped` or `restart: on-failure` on the
  application container.

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
  produce a line on stdout and nothing more. The smoke test asserts that against
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

[Unreleased]: https://github.com/quwisky/linuxserver-docker-mods/commits/master
