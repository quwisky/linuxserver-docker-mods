# Docker Mods

[LinuxServer.io Docker Mods](https://docs.linuxserver.io/general/container-customization/)
published to GHCR, grouped by the application each one mods.

A mod is a filesystem overlay: a single-layer `FROM scratch` image whose contents
are extracted into a running LinuxServer container at start-up by `/docker-mods`,
before s6 compiles its service database. That is why dropping files into
`/etc/s6-overlay/s6-rc.d/` from a mod works at all.

## Available mods

| Mod | For | What it does |
| --- | --- | --- |
| [plex-gluetun-portforward-mod](mods/plex/gluetun-portforward-mod/) | `linuxserver/plex` | Keeps Plex's public remote-access port in sync with the port [gluetun](https://github.com/qdm12/gluetun) forwards. |
| [plex-vaapi-amdgpu-mod](mods/plex/vaapi-amdgpu-mod/) | `linuxserver/plex` | Bundles modern Mesa and libva from Alpine edge so AMD GPUs, including RDNA4/gfx1151, can hardware transcode. `linux/amd64` only. |

Use one by adding it to `DOCKER_MODS` on the target container:

```yaml
environment:
  - DOCKER_MODS=ghcr.io/quwisky/plex-gluetun-portforward-mod:latest
```

Multiple mods are separated by `|`:

```yaml
  - DOCKER_MODS=ghcr.io/quwisky/plex-gluetun-portforward-mod:latest|linuxserver/mods:plex-absolute-hama
```

See each mod's own README for its environment variables and troubleshooting.

### Release channels

A mod at `mods/<app>/<mod>` is its own GHCR package named `<app>-<mod>`, with
ordinary tags:

| Image | Built from | When |
| --- | --- | --- |
| `ghcr.io/<owner>/<app>-<mod>:latest` | `master` | every push that changes the mod |
| `ghcr.io/<owner>/<app>-<mod>:<commit-sha>` | `master` | immutable pin of the above |
| `ghcr.io/<owner>/<app>-<mod>:nightly` | `develop` | nightly, if the mod changed |
| `ghcr.io/<owner>/<app>-<mod>:nightly-<tree-sha>` | `develop` | immutable pin of the above |
| `ghcr.io/<owner>/<app>-<mod>:<your-tag>` | any branch | manual run with a custom tag |

`:latest` is what you want. Nightlies exist to try changes before they reach
`master`:

```yaml
  - DOCKER_MODS=ghcr.io/quwisky/plex-gluetun-portforward-mod:nightly
```

Note that a container only re-applies a mod when it is **recreated**, not
restarted — `/docker-mods` caches the layer and skips it when the digest is
unchanged. `docker compose up -d --force-recreate <service>` picks up a new
nightly.

### Publishing a one-off tag

Run a mod's workflow from the Actions tab, pick any branch, and fill in the
**tag** field — `rc1`, `testing`, `v2-trial`. That builds the branch you chose
and publishes it as `ghcr.io/<owner>/<app>-<mod>:<your-tag>`, which you can then
point a real container at:

```yaml
  - DOCKER_MODS=ghcr.io/quwisky/plex-vaapi-amdgpu-mod:rc1
```

A custom tag publishes **only** that tag — it never also moves `:latest` or
`:nightly`, so trying something out on a branch cannot displace what everyone
else is pulling. It also skips the nightly's unchanged-content dedupe, since you
asked for this build explicitly.

`latest` and `nightly` are refused as custom tags. Publishing a channel is what
running the workflow from `master` or `develop` with the field left blank
already does, and accepting them here would mean a typo in a text box could
replace `:latest` with a build from an arbitrary branch.

## Layout

```
mods/
  <app>/                        one directory per application being modded
    <modname>/                  one mod
      Dockerfile                FROM scratch + COPY root/ /
      .dockerignore             keeps everything but root/ out of the image
      README.md                 that mod's documentation
      root/                     overlaid onto the target container's filesystem
      test/                     optional; whatever that mod ships (see below)
template/                       scaffold for a new mod, never built
ci/                             scaffolding and the workflow-coverage check
.github/workflows/
  mod-<app>-<modname>.yml       one per mod; carries that mod's paths filter
  _mod-ci.yml                   reusable; all the per-mod logic lives here once
  repo.yml                      repo-wide checks, always runs
```

**The two directory levels are the single source of truth.** A mod at
`mods/<app>/<modname>` is published as `ghcr.io/<owner>/<app>-<modname>` and its
workflow is `mod-<app>-<modname>.yml`. There is no separate config mapping
directories to images, so they cannot drift.

The app and the mod name stay separate all the way through CI rather than being
joined into one id, because the join is not reversible: LinuxServer image names
contain dashes of their own — `code-server` — so `code-server-python3` cannot be
split back into app and mod without guessing.

## Adding a mod

```bash
ci/new-mod.sh <app> <modname>            # e.g. ci/new-mod.sh plex remove-codecs
```

That copies `template/` to `mods/<app>/<modname>/`, rewrites the
placeholder names throughout — the s6 service directory names, the `up` file's
absolute path, the log prefix, the README heading — and writes that mod's CI
workflow at `.github/workflows/mod-<app>-<modname>.yml`.

Then:

1. Edit the mod's `README.md`, and add a row to the table above.
2. Delete whichever of the two example services you don't need — `init-mod-*`
   (a oneshot, run once before the app starts) or `svc-mod-*` (a longrun,
   supervised for the life of the container). Remove its entry from
   `root/etc/s6-overlay/s6-rc.d/user/contents.d/` and from
   `init-mods-end/dependencies.d/` at the same time.
3. Make sure any `run`/`finish` you keep is executable — see below.
4. Push. That mod's workflow tests it, and publishes
   `ghcr.io/<owner>/<app>-<modname>:latest` from `master`.

**After a mod's first successful build, set that package's visibility to
PUBLIC** on the repo's Packages page. GHCR packages are private by default, and
`/docker-mods` inside the target container then gets a 401 pulling the manifest —
the single most common "my mod doesn't load" cause. Because each mod is its own
package, this is once *per mod*, not once per repo; it is the one manual step
adding a mod still requires.

### Things that will silently not work

These are the failure modes that produce no error, just a mod that does nothing:

- **A non-executable `run`.** s6 ignores the service entirely. CI gates on this;
  fix locally with
  `find mods \( -name run -o -name finish -o -name check \) -not -perm -0111 -exec chmod +x {} +`
- **A service with no `user/contents.d/<name>` entry.** Nothing registers it into
  the user bundle, so it never starts. CI gates on this too.
- **CRLF line endings or a UTF-8 BOM.** The kernel tries to exec
  `/usr/bin/with-contenv\r` and reports "no such file or directory" for a file
  that plainly exists. `.gitattributes` pins LF; CI gates on both.
- **More than one image layer.** `/docker-mods` reads `.layers[0]` of the
  manifest and ignores the rest, so a second `COPY` or `RUN` in the final stage
  is dropped. Consolidate in a build stage instead. CI gates on this.
- **`#!/command/with-contenv bash`.** LinuxServer replaces `/usr/bin/with-contenv`
  with its own UMASK-aware wrapper that then calls the `/command` one. Use
  `#!/usr/bin/with-contenv bash`, or lose `UMASK` support.
- **`s6-setuidgid abc` without a guard.** Under `LSIO_NON_ROOT_USER` there is no
  `abc` user and it fails. Guard it, or avoid needing it.
- **`apt-get`/`apk` called directly.** Append to
  `/mod-repo-packages-to-install.list` and let the framework batch the install,
  then do dependent work in a second oneshot ordered after
  `init-mods-package-install`.

## CI

**One workflow per mod**, each gated on its own directory:

```
.github/workflows/mod-plex-gluetun-portforward-mod.yml
  on.push.paths: ['mods/plex/gluetun-portforward-mod/**', ...]
  jobs.ci.uses:  ./.github/workflows/_mod-ci.yml
```

GitHub only supports `paths:` at the workflow level, not per job, so this is
what actually makes a mod's CI run *only* when that mod changes — touching one
mod never runs another's tests, and each mod gets its own entry in the Actions
tab and its own status check. All the logic lives once in the reusable
`_mod-ci.yml`, so a caller is ~25 generated lines.

Each caller also triggers on `_mod-ci.yml` itself, so a change to the shared
pipeline is exercised against every mod.

### Branches and nightlies

`master` is the release branch and the default branch. `develop` is the
integration branch, and each mod's workflow carries a `schedule:` that builds it
nightly.

Two things about scheduled runs in GitHub Actions are worth knowing, because
they are not obvious and they shape this design:

- **`schedule` only ever fires from the default branch's copy of a workflow.**
  You cannot schedule a workflow to run *on* `develop`. So the nightly runs from
  `master`'s workflow file and checks `develop` out explicitly. The practical
  consequence: a mod added on `develop` gets no nightlies until its workflow
  file reaches `master`.
- **Everything scheduled for the same minute is queued together**, and GitHub
  drops scheduled runs under load. `ci/new-mod.sh` therefore derives each mod's
  cron slot from a hash of its name, spreading them across 02:00–05:59 UTC, and
  `ci/check-mod-workflows.sh` fails on a collision.

A nightly runs the full test suite every night even when the mod has not
changed — the smoke harness pulls `bash:5` and `caddy:2-alpine`, so upstream
breakage surfaces in CI rather than in someone's container. Only the *publish*
is skipped when nothing changed, which is what the content-addressed
`-nightly-<tree-sha>` pin is for: the tag is the git tree hash of
`mods/<app>/<mod>`, so unchanged content resolves to a tag that already exists and
the push is a no-op instead of registry churn.

Pushes to `develop` and to feature branches, and all pull requests, test without
publishing. A manual `workflow_dispatch` from `master` or `develop` publishes to
the matching channel without waiting for a commit or for the cron.

If `develop` does not exist yet, the nightly reports that once as a notice and
exits cleanly rather than failing red every night.

The cost of this design is that **a mod with no workflow is silently never
built or tested**. `repo.yml` therefore runs on every push with no paths filter,
and `ci/check-mod-workflows.sh` fails the build when a mod has no caller, a
caller points at a mod that no longer exists, a caller passes the wrong mod
name, or a caller has lost its paths filter. `ci/new-mod.sh` writes a correct
caller so this normally takes care of itself.

`repo.yml` additionally scaffolds a throwaway mod from `template/` into a temp
directory and applies the same structural rules a real mod must pass — the
template is not built by anything, so it would otherwise rot unnoticed.

## Testing

Each mod owns its own `test/` directory; its workflow runs whatever is there and
skips what isn't. The conventions it looks for:

| Path | Run as |
| --- | --- |
| `test/run_tests.sh` | unit tests, twice — plain, then with `NO_JQ=1` to exercise any pure-shell fallback |
| `test/smoke.sh` | end-to-end against stubbed services, no bind mounts so it works in CI |
| `test/stubs/Caddyfile.*` | validated with `caddy validate` |
| `test/docker-compose.test.yml` | not run in CI; the interactive local harness |

Alongside those, each mod's workflow checks encoding, executable bits, service
registration, and that the mod builds to exactly one layer containing nothing
but its overlay.

Run a mod's tests locally:

```bash
bash mods/<app>/<mod>/test/run_tests.sh
bash mods/<app>/<mod>/test/smoke.sh
shellcheck -x $(find mods/<app>/<mod> -type f \( -name run -o -name finish -o -name '*.sh' \))
```

Unit tests generally need bash 4+ (`declare -A`, `mapfile`, `${VAR,,}`). macOS
ships bash 3.2, so on a Mac run them in a container:

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt bash:5 sh -c 'apk add -q jq && bash mods/<app>/<mod>/test/run_tests.sh'
```

## License

MIT.
