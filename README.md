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
| [universal-gluetun-netns-watchdog-mod](mods/universal/gluetun-netns-watchdog-mod/) | Any current LinuxServer image | Restarts a container that Docker leaves stranded in Gluetun's destroyed network namespace. |

Use one by adding it to `DOCKER_MODS` on the target container:

```yaml
environment:
  - DOCKER_MODS=ghcr.io/quwisky/plex-gluetun-portforward-mod:1
```

Multiple mods are separated by `|`:

```yaml
  - DOCKER_MODS=ghcr.io/quwisky/plex-gluetun-portforward-mod:1|linuxserver/mods:plex-absolute-hama
```

See each mod's own README for its environment variables and troubleshooting.

### Releases and test images

A mod at `mods/<app>/<mod>` is independently versioned and published as the GHCR
package `<app>-<mod>`:

| Tag | Meaning |
| --- | --- |
| `:1.4.2` | Exact immutable release |
| `:1.4` | Latest compatible patch in the minor line |
| `:1` | Latest compatible release in the major line; recommended |
| `:latest` | Newest release, including future breaking majors |
| `:edge` | Last verified relevant commit on `master`; testing only |
| `:sha-<commit>` | Immutable candidate built from one `master` commit |
| `:test-<commit>` | Maintainer-approved, short-lived feature image |

Use the current major tag for normal installations. It receives compatible
patches and features without silently crossing a breaking major:

```yaml
  - DOCKER_MODS=ghcr.io/quwisky/plex-gluetun-portforward-mod:1
```

Note that a container only re-applies a mod when it is **recreated**, not
restarted — `/docker-mods` caches the layer and skips it when the digest is
unchanged. `docker compose up -d --force-recreate <service>` picks up a release.

### Testing unreleased work

Pull requests build and test without publishing. A maintainer requests a test
image through the default-branch-only repository event, then approves the
`test-publish` environment:

```bash
gh api --method POST repos/quwisky/linuxserver-docker-mods/dispatches \
  -f event_type=publish-test-image \
  -f 'client_payload[app]=plex' \
  -f 'client_payload[mod]=vaapi-amdgpu-mod' \
  -f 'client_payload[ref]=feature-branch'
```

The run returns a constrained `test-<commit>` tag:

```yaml
  - DOCKER_MODS=ghcr.io/quwisky/plex-vaapi-amdgpu-mod:test-a1b2c3d4e5f6
```

Arbitrary tag names are not accepted. The newest five test-only images per
package are retained; formal release and candidate tags cannot be displaced by
this workflow.

## Layout

```
mods/
  <app>/                        one directory per application being modded
    <modname>/                  one mod
      Dockerfile                FROM scratch; COPY paths are repo-relative
      README.md                 that mod's documentation
      VERSION                   current independent SemVer version
      CHANGELOG.md              package-specific release history
      PLATFORMS                 optional build-platform override
      root/                     overlaid onto the target container's filesystem
      test/                     optional; whatever that mod ships (see below)
shared/
  <name>/                       code more than one mod overlays; see below
template/                       scaffold for a new mod, never built
ci/                             scaffolding and the repo-wide checks
.dockerignore                   context is the repo root, so this lives here
.github/workflows/
  ci.yml                        affected-package matrix and required gate
  edge.yml                      trusted master-only edge publication
  _mod-ci.yml                   reusable read-only package validation
  _mod-publish.yml              trusted candidate publication and promotion
  release-please.yml            combined release PR and draft releases
  publish-releases.yml          trusted draft completion and image promotion
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

Two things follow, both derived from Dockerfile `COPY` statements:

- `ci/release.py affected` expands a shared change to every consuming package,
  so all affected images are tested and `edge` moves only after verification.
- Every consumer records a generated hash of its shared inputs. CI rejects a
  shared change until those package-local markers are refreshed, keeping
  Release Please's package paths aligned with the images that actually change.

**The two directory levels are the single source of truth.** A mod at
`mods/<app>/<modname>` is published as `ghcr.io/<owner>/<app>-<modname>`. There
is no separate config mapping directories to images, so they cannot drift.

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
absolute path, the log prefix, and the README heading — and initializes its
independent version and changelog.

Then:

1. Edit the mod's `README.md`, and add a row to the table above.
2. Delete whichever of the two example services you don't need — `init-mod-*`
   (a oneshot, run once before the app starts) or `svc-mod-*` (a longrun,
   supervised for the life of the container). Remove its entry from
   `root/etc/s6-overlay/s6-rc.d/user/contents.d/` and from
   `init-mods-end/dependencies.d/` at the same time.
3. Make sure any `run`/`finish` you keep is executable — see below.
4. Open a pull request with a Conventional Commit title. The scaffold registers
   the new package with Release Please, and the aggregate workflow discovers and
   tests it automatically. Use `feat(<modname>): ...` for its initial release.

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
- **`with-contenv` on a script the *application* invokes.** It REPLACES the
  environment with the container's, so anything the caller exported is gone.
  That is what you want for an s6 service, which has no caller — and fatal for
  a hook like Duplicati's `--run-script-after`, which passes its entire payload
  in environment variables. Measured in a real image:

  ```
  #!/usr/bin/env bash            DUPLICATI__EVENTNAME=AFTER
  #!/usr/bin/with-contenv bash   DUPLICATI__EVENTNAME=
  ```

  Such a script needs a plain shebang. It still sees the container's own
  variables, because the application was itself started under `with-contenv` and
  children inherit.
- **Writing to stderr from a script an application invokes.** Duplicati raises a
  warning against the operation for any stderr output at all
  (`RunScript-StdErrorNotEmpty`); other applications have their own version of
  this. Use stdout unless you mean to be reported as a problem.
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

`ci.yml` runs for every pull request. It derives one dynamic
matrix from the changed paths, expands shared inputs to their Dockerfile
consumers, and reports one stable branch-protection result: `CI / required`.
Repository contracts, Conventional release-intent validation, shared-marker
integrity, strict documentation, and every affected mod's unit, smoke, shell,
layer, and manifest checks sit below that gate.

Pull requests never receive secrets or publication permissions. The separate
master-push-only `edge.yml` validates each relevant package, builds it once as
`sha-<commit>`, verified from GHCR using the exact manifest headers
`/docker-mods` sends, and only then promoted remotely to `edge`. The newest 20
unreleased candidates are retained; candidates backing releases are permanent.

### Release automation

Release Please runs in manifest mode after each trusted `master` push. The
repository GitHub App maintains one combined
`release-please--branches--master` pull request, updates each affected package's
`VERSION` and `CHANGELOG.md`, and creates exact `<package>/vX.Y.Z` tags and draft
GitHub Releases when that pull request is squash-merged.

After each run, the same App token keeps an open release pull request current
with `master` through GitHub's update-branch API. This preserves App-only branch
ownership while satisfying the strict up-to-date merge requirement, even when
non-release maintenance commits do not change Release Please's generated files.

The squash-merge pull-request title is the release signal for every affected
package: `fix` makes a patch, `feat` makes a minor, and `!` or a
`BREAKING CHANGE:` footer makes a major. `chore`, `build`, `ci`, `docs`, `test`,
`refactor`, `style`, and `revert` do not release. Mixed release sizes must be
split into separate pull requests. `Release-As`, prereleases, direct release
branches, and manual release dispatches are rejected.

When shared files change, refresh and commit the deterministic consumer markers:

```bash
python3 ci/release.py shared-markers --write
```

The publisher discovers Release Please drafts and completes each package
independently. Ordinary releases build once from the exact tag; a real VAAPI
artifact update reuses the reviewed probe candidate. After manifest checks,
SemVer alias promotion, SBOM upload, and provenance attestation, the publisher
adds the verified image digest to the release and removes its draft status.
Failed drafts stay resumable and are never silently discarded.

Release runs are serialized and idempotent. A rerun verifies any completed tag
and continues from the same authorized source commit; releases have no manual
dispatch path and never rebuild or rewrite an immutable version. Emergency
rollback is a separately approved workflow that can temporarily repoint only
`latest` to an older verified digest. It records that action in the release.

The VAAPI mod is the one scheduled exception: a weekly dependency probe
fingerprints only the Alpine-derived files actually shipped. Its bootstrap PR
is a non-releasing `chore`; it opens a reviewed `fix` PR with an auditable
candidate only when those bytes, modes, or symlinks change. Renovate maintains
the pinned Alpine base digest with a non-releasing `chore(deps)` pull request.

Later probes compare against the released baseline or an already-open update
PR, so the same candidate is not replaced when review spans another weekly run.

SemVer is package-specific:

- **patch** — fixes, dependency refreshes, or internal changes that preserve the
  documented contract;
- **minor** — additive behavior, options, or supported platforms;
- **major** — removed or renamed configuration, user-visible default changes,
  platform removal, or incompatible runtime requirements.

### Repository setup

Release automation requires a repository-installed GitHub App whose id and
private key are stored as `RELEASE_APP_ID` and `RELEASE_APP_PRIVATE_KEY`. Set
the exact App bot login in the `RELEASE_APP_LOGIN` repository variable. Grant
only the repository permissions used here: Contents, Pull requests, and Issues
write.
Protect `master` with required pull requests, current branches, resolved
conversations, and the single `CI / required` check. A ruleset should restrict
`<package>/v*` tag creation to the release App and deny tag updates/deletion.
Restrict updates to `release-please--branches--master` to that App as well; CI
rejects generated release changes from every other branch and validates the
branch's allowed file structure.

Create `release`, `test-publish`, and `rollback` environments. All three require
maintainer approval. Install Renovate, leave automerge disabled,
review its pinned Release Please Action updates, and use GitHub Actions as the
Pages source.

## Documentation

The site is built once from `master` with MkDocs Material and deployed to
[GitHub Pages](https://quwisky.github.io/linuxserver-docker-mods/). There is no
second documentation channel: unreleased images are explicitly identified by
their `edge` or `test-*` tag instead.

The tracked `docs/agents/` directory contains engineering-skill configuration
and is excluded from the public site. `ci/build-docs.sh` preserves that directory
while generating the site pages from the READMEs — this file becomes the home
page, and each `mods/<app>/<mod>/README.md` becomes a page — then rewrites the
links that only make sense in a checkout so they resolve on the site. Keeping a
hand-written second copy of the published content would drift, and the READMEs
are what GitHub and the GHCR package pages render anyway.

The root [`CHANGELOG.md`](CHANGELOG.md) records repository-wide migration
history. Each package page links to the package-local changelog generated by
Release Please from reviewed Conventional Commit pull-request titles.

Build it locally:

```bash
pip install -r ci/docs-requirements.txt
ci/build-docs.sh
mkdocs serve            # http://127.0.0.1:8000
```

`mkdocs build --strict` is what CI runs; `--strict` promotes warnings to errors,
which catches a link the generator failed to rewrite. Pages must use **GitHub
Actions** as its source and allow deployments from `master`.

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
