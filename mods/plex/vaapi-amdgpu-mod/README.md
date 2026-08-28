# AMD VAAPI - Docker mod for plex

This mod makes VAAPI hardware transcoding work on AMD GPUs that Plex's own
bundled libraries are too old to recognise, by shipping a current Mesa and libva
and making Plex load them.

In plex docker arguments, set an environment variable
`DOCKER_MODS=ghcr.io/quwisky/plex-vaapi-amdgpu-mod:latest`

If adding multiple mods, enter them in an array separated by `|`, such as
`DOCKER_MODS=ghcr.io/quwisky/plex-vaapi-amdgpu-mod:latest|linuxserver/mods:plex-absolute-hama`

Nightly builds from `develop` are published as
`ghcr.io/quwisky/plex-vaapi-amdgpu-mod:nightly`. A container only re-applies a
mod when it is recreated, not restarted, so use
`docker compose up -d --force-recreate plex` to pick one up.

> **Fork of
> [`justinappler/plex-vaapi-amdgpu-mod`](https://github.com/justinappler/plex-vaapi-amdgpu-mod)**
> — rebuilt with modern Mesa to support new AMD GPUs (RDNA4/gfx1151).

---

## What it does

You have a recent AMD GPU — a Radeon 8060S, say, gfx1151 / RDNA4 — and VAAPI is
perfectly happy on the host:

```console
$ vainfo
libva info: VA-API version 1.22.0
vainfo: Supported profile and target: VAProfileH264Main : VAEntrypointVLD/VAEntrypointEncSlice
```

Inside the Plex container it fails anyway:

```
libva: radeonsi_drv_video.so init failed
Failed to initialise VAAPI connection: -1 (unknown libva error)
```

Three things cause that, and they compound:

1. **Plex bundles old libraries.** It ships musl-compiled binaries against a
   libdrm that predates your GPU, so the card is never identified.
2. **Plex's libdrm has a hardcoded `amdgpu.ids` path** baked in from their build
   machine, which does not exist in the container. The path changes between Plex
   releases.
3. **`linuxserver/plex` ships no libva**, because Plex is expected to bring its
   own — and the one it brings is as old as the rest.

The mod bundles Mesa, libva and their dependencies from Alpine edge, and then
makes Plex actually use them rather than its own copies. It does that by
replacing two Plex binaries with wrapper scripts:

| Change | Where | Why |
| --- | --- | --- |
| `Plex Transcoder` → wrapper | `/usr/lib/plexmediaserver/` | Sets `LD_LIBRARY_PATH`, `LIBVA_DRIVERS_PATH` and `LIBVA_DRIVER_NAME` so the transcoder loads this mod's stack. The original moves to `Plex Transcoder.orig`. |
| `Plex Media Server` → wrapper | `/usr/lib/plexmediaserver/` | Hardware detection also happens in the main process, so it needs the same environment. Original moves to `.orig`. |
| `amdgpu.ids` symlink | Plex's hardcoded build path | The path is found by scanning Plex's own libraries for it, so it keeps working when Plex changes it. |
| VA driver symlink | Plex's `va-dri-linux-x86_64` cache under `/config` | Where Plex looks for VA drivers. |

Both wrappers are idempotent: they check for the `.orig` file and do nothing if
it already exists. Everything under `/usr/lib` lives in the container's
ephemeral layer, so recreating the container starts from a clean Plex install
and the mod re-applies itself.

The only thing it writes to `/config` is inside Plex's own cache directory: the
VA driver symlinks, and a `mesa-shader-cache` directory the wrappers point Mesa
at so it does not try to write somewhere read-only.

## Requirements

- The `linuxserver/plex` image.
- **`linux/amd64`.** The drivers are x86_64 and get linked into Plex's
  `va-dri-linux-x86_64` cache. There is no arm64 build and there is no point in
  one.
- **`/dev/dri` passed into the container**, with the container's user in the
  groups that own those device nodes — usually `video` and `render`.
- An AMD GPU that already works on the host. If `vainfo` fails there too, this
  mod will not help; fix the host first.

### Supported GPUs

The mod exists for GPUs that Plex's bundled libraries do not recognise, but it
does not stop older cards working.

| GPU | Architecture | Status |
| --- | --- | --- |
| Radeon 8060S | gfx1151 / RDNA4 | Tested, working |
| Radeon 8050S | gfx1151 / RDNA4 | Should work |
| Other RDNA4 | gfx115x | Should work |
| Older AMD GPUs | RDNA3, RDNA2, … | Should work |

If your GPU works with `vainfo` on the host but not inside Plex, this is the
mod's exact use case.

## Quick start

First export the numeric groups that own the host's DRM devices. Container group
names are not portable here: Compose resolves `video` and `render` inside the
image, while the mounted device nodes keep their host GIDs.

```bash
export VIDEO_GID="$(stat -c '%g' /dev/dri/card0)"
export RENDER_GID="$(stat -c '%g' /dev/dri/renderD128)"
```

If the host has no `renderD*` node, omit `RENDER_GID` and its `group_add` entry.

```yaml
services:
  plex:
    image: lscr.io/linuxserver/plex:latest
    container_name: plex
    devices:
      # Required. Without this there is no GPU inside the container at all.
      - /dev/dri:/dev/dri
    group_add:
      # Numeric host GIDs are required; same-named container groups can differ.
      - "${VIDEO_GID}"
      - "${RENDER_GID}"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Amsterdam
      - VERSION=docker
      - DOCKER_MODS=ghcr.io/quwisky/plex-vaapi-amdgpu-mod:latest
    volumes:
      - ./plex/config:/config
      - /path/to/media:/media
    restart: unless-stopped
```

Then enable **Settings → Transcoder → Use hardware acceleration when available**
in Plex.

## Configuration

There is none — the mod has no environment variables. It detects what it needs
at container start, including the `amdgpu.ids` path Plex expects, which it finds
by scanning Plex's own libraries rather than hardcoding a value that changes
with every Plex release.

## How it works

At container start, as an s6-overlay oneshot ordered after the mod init phase:

1. **Finds Plex's hardcoded `amdgpu.ids` paths.** Plex's build system bakes an
   absolute path from its own CI runner into the shipped libraries. The mod
   greps the binaries for it and symlinks its own `amdgpu.ids` into place, so
   libdrm can identify the card.
2. **Wraps `Plex Transcoder`.** The real binary moves to `.orig` and a small
   script takes its name, exporting `LD_LIBRARY_PATH=/vaapi-amdgpu/lib`,
   `LIBVA_DRIVERS_PATH=/vaapi-amdgpu/lib/dri` and `LIBVA_DRIVER_NAME=radeonsi`
   before exec'ing the original.
3. **Wraps `Plex Media Server` the same way**, because the main process does its
   own hardware detection.
4. **Symlinks the VA driver** into Plex's `va-dri-linux-x86_64` cache.

At runtime the wrappers mean Plex resolves libva and the radeonsi driver to this
mod's copies instead of its own, and the driver initialises against a libdrm
that knows what your GPU is.

### Bundled components

Everything is taken from Alpine edge at **build** time, which is why the image is
rebuilt on a schedule rather than only when the source changes.

| Component | Purpose |
| --- | --- |
| `radeonsi_drv_video.so` | The AMD VA driver from Mesa |
| `libva*.so` | VA-API, matched to the driver it was built against |
| `libdrm*.so` | DRM libraries new enough to identify current GPUs |
| `libLLVM*.so` | LLVM runtime that Mesa's shader compiler needs |
| `amdgpu.ids` | The GPU identification database |
| `ld-musl-x86_64.so.1`, `libc.musl-x86_64.so.1` | musl loader and libc |
| …plus every transitive dependency | Resolved with `ldd` at build time |

### Why Alpine, and why musl

Plex Media Server is compiled against musl, not glibc, so its libraries have to
be musl too. You can see it for yourself:

```bash
docker exec plex ls /usr/lib/plexmediaserver/lib/ | grep musl
# ld-musl-x86_64.so.1
```

That is the whole reason the build stage is Alpine rather than Ubuntu: it is the
convenient source of current, musl-linked Mesa.

## Verifying it works

```bash
docker logs plex 2>&1 | grep -A20 'Setting up AMD VAAPI'
```

A healthy start looks like this:

```
**** Setting up AMD VAAPI drivers ****
Scanning for hardcoded amdgpu.ids paths...
Found hardcoded path: /home/runner/work/.../amdgpu.ids
  -> Symlinked
Creating Plex Transcoder wrapper...
Transcoder wrapper created
Creating Plex Media Server wrapper...
Plex Media Server wrapper created
Linked driver: radeonsi_drv_video.so
amdgpu.ids present at /usr/share/libdrm/amdgpu.ids
**** AMD VAAPI setup complete ****
```

On a container that has already been through this once, the two wrapper lines
read `… wrapper already exists` instead. That is correct, not a failure.

Then transcode something and check Plex's own log:

```
TPU: hardware transcoding: final decoder: vaapi, final encoder: vaapi
```

Both halves saying `vaapi` is the confirmation. In the dashboard, an active
transcode shows `(hw)` — for example `Video: HEVC → H264 (hw)`.

## Troubleshooting

| What you see | What it means |
| --- | --- |
| `No hardcoded paths found (GPU may show as 'Unknown AMD' - cosmetic only)` | Plex changed how it references `amdgpu.ids`, or this build has no such path. Transcoding still works; only the GPU's display name suffers. |
| `WARNING: amdgpu.ids not found at /usr/share/libdrm/amdgpu.ids` | The mod layer did not extract properly. Recreate the container so `/docker-mods` re-applies it. |
| `Transcoder wrapper already exists` | Normal on any container that has started before. |
| `libva: radeonsi_drv_video.so init failed` *after* installing the mod | The wrappers are not being used, or the mod was not applied. See the two checks below. |
| `Permission denied` opening `/dev/dri/renderD128` | The device is passed through but the container user lacks its host GID. Re-run the `stat` commands in Quick start and use those numeric values under `group_add`. |
| `Unknown AMD (XXXX)` in Plex | Cosmetic. Plex has no marketing name for the card; transcoding is unaffected. |
| `amdgpu: os_same_file_description couldn't determine if two DRM fds…` | A harmless Mesa warning. |
| `Critical: libusb_init failed` | Unrelated to transcoding — Plex itself says to ignore it. |

If transcoding still fails, check the two things that actually go wrong:

```bash
# 1. Are the wrappers in place? This should print a shell script, not ELF bytes.
docker exec plex head -5 "/usr/lib/plexmediaserver/Plex Transcoder"

# 2. Are the libraries there?
docker exec plex ls /vaapi-amdgpu/lib/
```

If the wrappers are missing, the mod did not run. Recreate the container rather
than restarting it — `/docker-mods` caches the layer and a restart will not
re-apply it:

```bash
docker compose up -d --force-recreate plex
```

## Limitations

- **`linux/amd64` only.** See Requirements.
- **It replaces two Plex binaries.** They are moved to `.orig` and shadowed by
  wrapper scripts. This is contained to the container's ephemeral layer, but it
  does mean `Plex Transcoder` is not the file Plex shipped.
- **Mesa comes from Alpine edge**, which is a rolling target. A monthly rebuild
  is what keeps new GPU support arriving, and it is also what makes a regression
  possible — pin a dated tag if you need a build to stay put.
- It does nothing for Intel or NVIDIA hardware.

## Building your own image

1. Fork this repo. The published package name is composed from both directory
   levels — `mods/<app>/<mod>` becomes `<app>-<mod>` — so leaving this at
   `mods/plex/vaapi-amdgpu-mod` keeps it `plex-vaapi-amdgpu-mod`.
2. Push to `master`. This mod's own workflow builds and publishes it to GHCR with
   the built-in `GITHUB_TOKEN` — no Docker Hub account and no PAT needed.
3. **Set the `plex-vaapi-amdgpu-mod` package's visibility to public** on the
   repo's Packages page. GHCR packages are private by default, and
   `/docker-mods` then gets a 401 pulling the manifest. This is the single most
   common "my mod doesn't load" cause.
4. Point `DOCKER_MODS` at `ghcr.io/<your-user>/plex-vaapi-amdgpu-mod:latest`.

Published tags:

| Tag | From | Notes |
| --- | --- | --- |
| `:latest` | `master` | What you want. Also rebuilt monthly for fresh Mesa. |
| `:<commit-sha>-<YYYYMMDD>-<run-id>` | `master` | Immutable. Pin this to hold a known-good Mesa snapshot. |
| `:nightly` | `develop` | Changes before they reach `:latest`. |
| `:nightly-<tree-sha>-<YYYYMMDD>-<run-id>` | `develop` | Immutable nightly pin. |
| `:<your-tag>` | any branch | A manual run with the **tag** field filled in. Publishes that tag alone, leaving `:latest` and `:nightly` untouched. |

The run id is what keeps those immutable. This mod opts out of the
content-addressed dedupe — its image comes from `alpine:edge`, so an unchanged
git tree does *not* mean an unchanged image — which means two rebuilds on the
same day would otherwise land on the same date-stamped tag and the second would
overwrite the first.

Tags in the older `mesa-edge-YYYY-MM-DD` format were published while this mod
lived in its own repository. They still resolve, but new builds do not use that
format.

## Local development

All paths below are relative to the repo root.

```bash
# amd64 is not optional: the drivers are x86_64 and get linked into Plex's
# va-dri-linux-x86_64 cache.
docker build --platform linux/amd64 \
  -f mods/plex/vaapi-amdgpu-mod/Dockerfile -t local/vaapi .
```

Inspect what actually ends up in the layer — it should be the s6 tree,
`usr/share/libdrm/amdgpu.ids`, and `vaapi-amdgpu/lib/`, and nothing else:

```bash
docker create --name probe local/vaapi /nonexistent
docker export probe | tar -tf - | grep -vE '^(dev|proc|sys)/' | sort
docker rm probe
```

A mod must be exactly one layer, because `/docker-mods` only ever pulls
`.layers[0]` of the manifest:

```bash
docker image inspect local/vaapi --format '{{len .RootFS.Layers}}'
```

The smoke test builds that layer into the current `linuxserver/plex` image,
starts Plex with an empty `/config` as `PUID=1000`/`PGID=1000`, checks the Mesa
dependency closure, and verifies both a fresh setup and repair of directories
created by an older release with the wrong ownership:

```bash
bash mods/plex/vaapi-amdgpu-mod/test/smoke.sh
```

To try it against a real container, point `DOCKER_MODS` at the local tag and
recreate:

```bash
DOCKER_MODS=local/vaapi docker compose up -d --force-recreate plex
```

Before pushing:

```bash
shellcheck -x mods/plex/vaapi-amdgpu-mod/root/etc/s6-overlay/s6-rc.d/*/run
bash mods/plex/vaapi-amdgpu-mod/test/smoke.sh

# s6 silently ignores non-executable service scripts, so this must print nothing
find mods/plex/vaapi-amdgpu-mod \( -name run -o -name finish -o -name check \) \
  -not -perm -0111 -print
```

## Credits

Fork of
[justinappler/plex-vaapi-amdgpu-mod](https://github.com/justinappler/plex-vaapi-amdgpu-mod).

## License

MIT.
