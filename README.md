# Docker Mods

[LinuxServer.io Docker Mods](https://docs.linuxserver.io/general/container-customization/)
published to GHCR, grouped by the application each one mods.

A mod is a filesystem overlay: a single-layer `FROM scratch` image whose contents
are extracted into a running LinuxServer container at start-up by `/docker-mods`,
before s6 compiles its service database. That is why dropping files into
`/etc/s6-overlay/s6-rc.d/` from a mod works at all.

📖 **[Documentation site](https://quwisky.github.io/linuxserver-docker-mods/)** —
the same content as these READMEs, rendered and searchable. ·
**[Changelog](CHANGELOG.md)**

## Available mods

| Mod | For | What it does |
| --- | --- | --- |
| [duplicati-discord-notify-mod](mods/duplicati/discord-notify-mod/) | `linuxserver/duplicati` | Posts a colour-coded Discord embed after every Duplicati operation, with the statistics, the destination and the errors Duplicati reported. |
| [plex-gluetun-portforward-mod](mods/plex/gluetun-portforward-mod/) | `linuxserver/plex` | Keeps Plex's public remote-access port in sync with the port [gluetun](https://github.com/qdm12/gluetun) forwards. |
| [plex-vaapi-amdgpu-mod](mods/plex/vaapi-amdgpu-mod/) | `linuxserver/plex` | Bundles modern Mesa and libva from Alpine edge so AMD GPUs, including RDNA4/gfx1151, can hardware transcode. `linux/amd64` only. |
| [qbittorrent-gluetun-portforward-mod](mods/qbittorrent/gluetun-portforward-mod/) | `linuxserver/qbittorrent` | Keeps qBittorrent's listening port in sync with the port [gluetun](https://github.com/qdm12/gluetun) forwards, and re-applies it after an outage. |

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
      Dockerfile                FROM scratch; COPY paths are repo-relative
      README.md                 that mod's documentation
      root/                     overlaid onto the target container's filesystem
      test/                     optional; whatever that mod ships (see below)
shared/
  <name>/                       code more than one mod overlays; see below
template/                       scaffold for a new mod, never built
ci/                             scaffolding and the repo-wide checks
.dockerignore                   context is the repo root, so this lives here
.github/workflows/
  mod-<app>-<modname>.yml       one per mod; carries that mod's paths filter
  _mod-ci.yml                   reusable; all the per-mod logic lives here once
  repo.yml                      repo-wide checks, always runs
```

### Sharing code between mods

Each mod is its own single-layer image, so there is no include mechanism: a file
two mods both need has to reach both images somehow. It lives once under
`shared/`, and the **build context is the repo root** rather than the mod
directory, which is what makes it reachable.

The single-layer rule still holds, because the assembly happens in a stage:

```dockerfile
FROM scratch AS assemble
COPY mods/<app>/<mod>/root/ /
COPY shared/<name>/ /usr/local/lib/<name>/

FROM scratch
COPY --from=assemble / /        # one COPY in the final stage, one layer
```

A mod that shares nothing needs no assembly stage — a single
`COPY mods/<app>/<mod>/root/ /` is still one layer, and that is what
`template/` scaffolds.

Two things follow, both enforced by `ci/check-shared-files.sh` from `repo.yml`:

- **A mod using `shared/<name>` must add `'shared/<name>/**'` to its workflow's
  `paths:` filter.** Per-mod workflows are gated on their own directory, so
  without it a change to the shared code would alter that mod's image without
  running its tests or its build — the same silent failure as having no workflow.
- **The nightly pin must cover it too.** That pin is content-addressed, and
  `ci/mod-inputs.sh` derives the hash from the mod directory *plus* every
  `shared/` directory the Dockerfile copies. Hashing the mod directory alone
  would make a shared-code change produce a different image under a pin that
  already exists, so the publish would be skipped — silently, and every night.

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
- **The wrong manifest media type.** `/docker-mods` fetches the manifest sending
  only `application/vnd.docker.distribution.manifest.v2+json` and
  `application/vnd.oci.image.index.v1+json`. A multi-platform build produces an
  OCI *index*, which is accepted; a single-platform build produces a bare OCI
  *image manifest*, which is not — the registry answers `404 MANIFEST_UNKNOWN`
  and the mod quietly falls back to its cache, so on a fresh container it never
  loads. `_mod-ci.yml` therefore publishes Docker media types for
  single-platform mods, and asserts after every publish that the manifest is
  actually readable with those exact Accept headers.
- **`#!/command/with-contenv bash`.** LinuxServer replaces `/usr/bin/with-contenv`
  with its own UMASK-aware wrapper that then calls the `/command` one. Use
  `#!/usr/bin/with-contenv bash`, or lose `UMASK` support.
- **`s6-setuidgid abc` without a guard.** Under `LSIO_NON_ROOT_USER` there is no
  `abc` user and it fails. Guard it, or avoid needing it.
- **`apt-get`/`apk` called directly.** Append to
  `/mod-repo-packages-to-install.list` and let the framework batch the install,
  then do dependent work in a second oneshot ordered after
  `init-mods-package-install`.
- **A oneshot in `init-mods-end/dependencies.d/` that does network I/O.** That
  registration is what makes the application wait for it, which is usually the
  point — but the app then waits for every timeout the oneshot can hit. A
  notification oneshot registered there was measured delaying Duplicati by 22
  seconds against an unreachable endpoint; leaving it out of `init-mods-end` and
  relying on its own `dependencies.d` for ordering cost nothing and still ran it.

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

## Documentation

The site is built with MkDocs Material and deployed to GitHub Pages in two
channels, matching the image tags:

| Site | Built from | Describes |
| --- | --- | --- |
| [quwisky.github.io/linuxserver-docker-mods](https://quwisky.github.io/linuxserver-docker-mods/) | `master` | the `:latest` images |
| [.../nightly/](https://quwisky.github.io/linuxserver-docker-mods/nightly/) | `develop` | the `:nightly` images |

Every page of both sites carries a **channel dropdown in the header**, beside
the palette toggle, with the channel you are on ticked and the other one a link.
The nightly site additionally shows a banner, since a dropdown states which
channel you are on only quietly. Its "view on GitHub" links point at `develop`
rather than `master`, so a nightly page links to the code it actually documents.

The dropdown is not Material's built-in version selector. That one is driven by
`mike` and fetches `versions.json` relative to `site_url`, which assumes every
channel sits in a subdirectory of its own — stable is served at the root here,
so the fetch would climb out of this Pages site entirely. Both URLs are known at
build time instead, so `overrides/partials/alternate.html` renders the entries
directly: no JavaScript, no extra request, and no restructuring of a published
URL people have already linked to.

That file replaces Material's **language** selector, which is what puts a
dropdown in that spot. The site is single-language, so the slot is free; the
override drops the `hreflang` the original emits, because telling a crawler that
stable and nightly are language variants of one another would be a lie. Material
still supplies everything around it, including the `.md-select` CSS that opens
the menu on hover and on keyboard focus.

**Pages allows exactly one deployment per repository**, so the two are not
deployed independently: every run of the docs workflow rebuilds *both* branches
into one tree and uploads it as a single artifact. A push to `develop` therefore
checks `master` out as well, and vice versa. The practical consequences are that
a deploy always publishes both channels as they stand at that moment, and that
`.github/workflows/docs.yml` has to exist on **both** branches — a push to
`master` running an older copy of it would publish a site with no `/nightly/`
until the next push to `develop` restored it.

If `develop` does not exist, the stable site is published on its own and the
workflow says so once as a notice. If `develop` exists but does not build,
`/nightly/` is replaced by a short page saying so and the stable site is
published anyway — `develop` is the integration branch and is allowed to be
briefly broken; withholding a good stable site because of it would be the wrong
way round.

There is no `docs/` directory in the repo. `ci/build-docs.sh` generates one from
the READMEs — this file becomes the home page, and each `mods/<app>/<mod>/README.md`
becomes a page — then rewrites the links that only make sense in a checkout so
they resolve on the site. Keeping a hand-written second copy of the same content
would drift, and the READMEs are what GitHub and the GHCR package pages render
anyway.

[`CHANGELOG.md`](CHANGELOG.md) is published alongside them. It is written by
hand: history here gets squashed, so a generator reading commit messages would
have almost nothing to work with, and the useful unit of change is what a new
image means for someone pulling it.

Build it locally:

```bash
pip install -r ci/docs-requirements.txt
ci/build-docs.sh
mkdocs serve            # http://127.0.0.1:8000
```

`mkdocs build --strict` is what CI runs; `--strict` promotes warnings to errors,
which is what catches a link the generator failed to rewrite. Adding a mod needs
no docs change — the page and its nav entry appear from the directory tree.

To preview what the nightly site looks like, set the same three variables the
workflow does. They reach `mkdocs.yml` through its `!ENV` tags, and unset —
which is every ordinary local build — they give the stable values:

```bash
DOCS_CHANNEL=nightly DOCS_SOURCE_BRANCH=develop \
  SITE_NAME='LinuxServer Docker Mods (nightly)' \
  ci/build-docs.sh && mkdocs serve
```

`overrides/` holds the repo's only two templates: `partials/alternate.html` for
the dropdown and `main.html` for the nightly banner. With `DOCS_CHANNEL` unset
the banner renders nothing and the dropdown ticks Stable — which is what you
want in a clone.

### Two one-time settings

Both fail in ways that read like a workflow bug rather than a setting, so they
are worth doing before the first deploy rather than diagnosing afterwards.

1. **Settings → Pages → Source** must be **GitHub Actions**. Until it is,
   `deploy-pages` fails with a "Pages site not found"-style error.
2. **Settings → Environments → `github-pages` → Deployment branches** must allow
   **`develop`** as well as `master`. GitHub restricts that environment to the
   default branch by default, so a push to `develop` builds both channels
   perfectly, uploads the artifact, and then fails on the last step with:

   ```
   Branch "develop" is not allowed to deploy to github-pages
   due to environment protection rules.
   ```

   Either add it in the UI, or:

   ```bash
   gh api --method POST \
     repos/<owner>/<repo>/environments/github-pages/deployment-branch-policies \
     -f name='develop' -f type='branch'
   ```

   This is what lets a change on `develop` reach `/nightly/` without waiting for
   a push to `master` — which is the entire point of having the channel.

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
