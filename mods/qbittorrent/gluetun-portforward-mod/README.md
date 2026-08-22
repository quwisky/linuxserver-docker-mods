# Gluetun port forward - Docker mod for qbittorrent

This mod keeps qBittorrent's listening port in sync with the port your VPN
provider forwards through [gluetun](https://github.com/qdm12/gluetun).

In qbittorrent docker arguments, set an environment variable
`DOCKER_MODS=ghcr.io/quwisky/qbittorrent-gluetun-portforward-mod:latest`

If adding multiple mods, enter them in an array separated by `|`, such as
`DOCKER_MODS=ghcr.io/quwisky/qbittorrent-gluetun-portforward-mod:latest|linuxserver/mods:universal-cron`

Nightly builds from `develop` are published as
`ghcr.io/quwisky/qbittorrent-gluetun-portforward-mod:nightly`. A container only
re-applies a mod when it is recreated, not restarted, so use
`docker compose up -d --force-recreate qbittorrent` to pick one up.

---

## What it does

Providers that support port forwarding hand out a **random high port**, and it
changes. ProtonVPN negotiates via NAT-PMP with a 60-second mapping lifetime that
gluetun refreshes every 45 seconds, and because the gateway picks the port,
almost every reconnect yields a different one. qBittorrent knows nothing about
any of this: it keeps listening on whatever port it was configured with, so
incoming connections stop arriving and you quietly become a passive,
outbound-only client — still downloading, barely seeding, with no error anywhere.

The mod polls gluetun's control server and pushes the current port into
qBittorrent through its WebUI API, live and with no restart. In steady state it
is silent; it logs when something changes and when something is wrong.

It writes these preferences, and only when one of them is actually wrong:

| Preference | Value | Why |
| --- | --- | --- |
| `listen_port` | the forwarded port | The port qBittorrent accepts incoming connections on. |
| `random_port` | `false` | A forwarded port is pointless if qBittorrent then picks its own at random. Opt out with `GLUETUN_PF_MANAGE_PORT_TOGGLES=false`. |
| `upnp` | `false` | UPnP/NAT-PMP would try to map a port on the VPN gateway, which is not a router that will answer. Same opt-out. |

And it never:

- edits `qBittorrent.conf` — qBittorrent rewrites that file from memory when it
  exits, so an edit made underneath a running client is simply lost. The WebUI
  API is the only correct way in.
- restarts qBittorrent
- touches any other preference, including your interface bindings

### The part that is not just "set the port"

qBittorrent does not reliably re-open its listening socket after the tunnel
drops. When the port comes back it can be holding the correct number in its
settings and still not be listening on it, so a mod that only writes on a
*changed* value leaves you passive until the port happens to change.

This mod tracks that: when gluetun reports no forwarded port, the next port it
sees is written **even if the value is unchanged**, which nudges qBittorrent into
re-binding. In the log that reads `re-applying 54321 after a port outage`.

## Requirements

- The `linuxserver/qbittorrent` image, qBittorrent 5.2 or thereabouts. No extra
  packages are installed: `bash`, `curl` and `jq` are already there.
- gluetun with `VPN_PORT_FORWARDING=on` and a provider that supports it: PIA,
  ProtonVPN, PrivateVPN or Perfect Privacy.
- gluetun's control server reachable from the qBittorrent container.
- **A way in to the WebUI.** See below — this is the one thing you have to
  decide.

### Letting the mod talk to qBittorrent

qBittorrent's API needs authentication, and since 4.6.1 the image prints a **new
temporary `admin` password on every start** unless you set a permanent one. That
temporary password is useless to a mod, because it changes underneath it.

Pick one:

- **Tick "Bypass authentication for clients on localhost"** in the WebUI, under
  Tools → Options → Web UI. The mod talks to loopback, so this is enough, and it
  keeps credentials out of your compose file. It is also what the gluetun
  documentation assumes.
- **Set a permanent WebUI password**, then pass it as
  `GLUETUN_PF_QBT_USERNAME` and `GLUETUN_PF_QBT_PASSWORD`. The mod logs in, keeps
  the session cookie, and silently logs in again whenever the session expires.

With neither, every API call comes back `403 Forbidden`, and the mod says so
once, with both fixes spelled out, rather than looping quietly.

> The mod deliberately sends no `Referer` or `Origin` header. qBittorrent's CSRF
> check rejects a *mismatched* origin but explicitly permits a request carrying
> neither — the source comment notes that blocking those "will inevitably lead
> Web API users to spoof headers". Sending nothing is simpler and safer than
> guessing a value that has to equal the `Host` header.

## Quick start

```yaml
services:
  gluetun:
    image: qmcgaw/gluetun:v3.41.2
    container_name: gluetun
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      # qBittorrent's WebUI is published HERE, not on the qbittorrent service,
      # because qbittorrent shares this container's network namespace.
      - 8080:8080/tcp
    volumes:
      # Must be persistent. PIA stores its forwarded port and signature here and
      # then keeps the same port for 60 days across restarts; lose this volume
      # and you get a new port every time.
      - ./gluetun:/gluetun
    environment:
      - VPN_SERVICE_PROVIDER=protonvpn
      - VPN_TYPE=wireguard
      - WIREGUARD_PRIVATE_KEY=<your key>
      - SERVER_COUNTRIES=Netherlands
      - PORT_FORWARD_ONLY=on
      - VPN_PORT_FORWARDING=on
      - VPN_PORT_FORWARDING_PROVIDER=protonvpn
      - TZ=Europe/Amsterdam
    restart: unless-stopped

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    # Share gluetun's network namespace. gluetun's control server is then at
    # localhost:8000 and the WebUI at localhost:8080.
    network_mode: service:gluetun
    depends_on:
      gluetun:
        condition: service_healthy
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Amsterdam
      - WEBUI_PORT=8080
      - DOCKER_MODS=ghcr.io/quwisky/qbittorrent-gluetun-portforward-mod:latest
      # Only if you chose credentials over the localhost bypass:
      # - GLUETUN_PF_QBT_USERNAME=admin
      # - GLUETUN_PF_QBT_PASSWORD=<your permanent WebUI password>
      # Everything below is optional and shown at its default.
      # - GLUETUN_PF_CONTROL_URL=http://localhost:8000
      # - GLUETUN_PF_INTERVAL=60
      # - GLUETUN_PF_LOG_LEVEL=info
    volumes:
      - ./qbittorrent/config:/config
      - /path/to/downloads:/downloads
    restart: unless-stopped
```

Two things about that file:

- **No `ports:` on the `qbittorrent` service.** Docker forbids it with
  `network_mode: service:`, and publishing 8080 on gluetun is what gets you to
  the WebUI.
- **No `VPN_PORT_FORWARDING_LISTENING_PORT`**, unlike the Plex mod. A torrent
  client announces its own port to peers and trackers, so it wants to listen on
  the *public* port directly — which is exactly what this mod arranges. Adding
  gluetun's redirect would break that, and the gluetun wiki warns against it for
  precisely this case.

## Environment variables

With `network_mode: service:gluetun` the defaults are already right, so adding
the mod to `DOCKER_MODS` and setting nothing else works — provided qBittorrent
will talk to it, see above.

### Core

| Variable | Default | Purpose |
| --- | --- | --- |
| `GLUETUN_PF_ENABLED` | `true` | Set falsey (`false`, `0`, `no`, `off`) to make the mod inert without editing `DOCKER_MODS`. The service is then brought permanently down, so changing this back needs a container recreate. |
| `GLUETUN_PF_CONTROL_URL` | `http://localhost:8000` | gluetun's control server. Use `http://gluetun:8000` if qBittorrent is on a shared bridge network instead of gluetun's namespace — and then also set `FIREWALL_INPUT_PORTS=8000` on gluetun. |
| `GLUETUN_PF_QBT_URL` | `http://localhost:${WEBUI_PORT:-8080}` | qBittorrent's WebUI. Follows the image's own `WEBUI_PORT`, so changing that is enough. |
| `GLUETUN_PF_INTERVAL` | `60` | Seconds between polls in steady state, clamped to ≥ 5. |
| `GLUETUN_PF_LOG_LEVEL` | `info` | `debug` adds a line per poll, including "already in sync". |

### qBittorrent authentication

Leave both unset to rely on the localhost bypass.

| Variable | Default | Purpose |
| --- | --- | --- |
| `GLUETUN_PF_QBT_USERNAME` | *(empty)* | WebUI username, usually `admin`. |
| `GLUETUN_PF_QBT_PASSWORD` | *(empty)* | WebUI password. Must be a permanent one — the temporary password printed on start changes every restart. |

### gluetun authentication

Only needed if you have mounted an auth `config.toml` on gluetun.

| Variable | Default | Purpose |
| --- | --- | --- |
| `GLUETUN_PF_APIKEY` | *(empty)* | Sent as the **`X-API-Key`** header. gluetun has no `Authorization: Bearer` support. |
| `GLUETUN_PF_USERNAME` | *(empty)* | HTTP basic auth username for gluetun. Ignored if `GLUETUN_PF_APIKEY` is set. |
| `GLUETUN_PF_PASSWORD` | *(empty)* | HTTP basic auth password for gluetun. |

Both secrets work with LinuxServer's `FILE__` convention, e.g.
`FILE__GLUETUN_PF_QBT_PASSWORD=/run/secrets/qbt_password`. Make sure the secret
file has **no trailing newline**.

### Advanced

| Variable | Default | Purpose |
| --- | --- | --- |
| `GLUETUN_PF_MANAGE_PORT_TOGGLES` | `true` | Also force `random_port` and `upnp` off. Set `false` to manage those yourself; the mod then only touches `listen_port`. |
| `GLUETUN_PF_PORT_INDEX` | `0` | Which port to use when your provider forwards several — Perfect Privacy always returns three, ProtonVPN up to five. `0` is the lowest, which is also the one gluetun itself reports as `port`. |
| `GLUETUN_PF_RETRY_INTERVAL` | `10` | Seconds between retries while waiting for prerequisites. Clamped to ≥ 2. |
| `GLUETUN_PF_TIMEOUT` | `10` | Per-request timeout. The connect timeout is fixed at 5 s. |

## Recovering from a gluetun restart (opt-in)

**Off by default.** This is the one feature here that can stop your container, so
it never arrives by surprise — nothing below happens until you set
`GLUETUN_PF_NETNS_WATCHDOG=true`.

### The problem

`network_mode: service:gluetun` joins gluetun's network namespace **by container
ID**. When the gluetun container *restarts* — not merely reconnects — that
namespace is destroyed and a new one is created. Docker never re-attaches
qBittorrent, so it is left stranded in the dead one: `eth0` went with the veth
pair, `tun0` went with gluetun's tun device, and only `lo` remains.

The result is a container that is up, healthy-looking, and completely isolated.
The WebUI is unreachable (its port is published on gluetun), nothing routes out,
and it stays that way until qBittorrent's container is restarted — at which point
Docker re-resolves `network_mode` against gluetun's *current* namespace and
everything works again.

### What the watchdog does

Each poll it looks for any non-loopback interface in `/sys/class/net`. If there
is none for several consecutive polls, it halts the container so Docker's restart
policy brings it back attached correctly.

That specific signal is what makes this safe: a VPN **reconnect** tears down
`tun0` but leaves `eth0` alone, so it cannot be mistaken for an orphaned
namespace. Reachability of gluetun's control server is deliberately *not* used —
it cannot tell a reconnect from an orphaning, and acting on it would restart your
container every time the VPN blipped.

### `restart: unless-stopped` is mandatory

Halting **is** the recovery mechanism; the restart policy is what completes it.
With no policy, the container simply stops and stays stopped. `unless-stopped` or
`on-failure` both work — the exit code is non-zero by default precisely so
`on-failure` does.

```yaml
  qbittorrent:
    network_mode: service:gluetun
    restart: unless-stopped          # <- without this the watchdog just stops it
    environment:
      - GLUETUN_PF_NETNS_WATCHDOG=true
```

### Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `GLUETUN_PF_NETNS_WATCHDOG` | `false` | The master switch. Everything below is inert until this is truthy. |
| `GLUETUN_PF_NETNS_WATCHDOG_DRY_RUN` | `false` | Log the decision and halt nothing. Use it to confirm the mod sees what you expect before arming it. |
| `GLUETUN_PF_NETNS_WATCHDOG_STRIKES` | `4` | Consecutive failed checks before halting. Clamped to ≥ 1. |
| `GLUETUN_PF_NETNS_WATCHDOG_GRACE` | `60` | Seconds after the service starts before the watchdog arms, because the namespace is still being set up early in container start. |
| `GLUETUN_PF_NETNS_WATCHDOG_EXIT_CODE` | `70` | Exit status. Must be 1–255, so `restart: on-failure` also works. |
| `GLUETUN_PF_NETNS_WATCHDOG_MAX_HALTS` | `3` | How many times it will halt in one container lifetime before concluding that halting is not helping and switching itself off. `0` means never give up. |

### When halting does not help

Halting only recovers the container if it actually comes back. If it does not —
no `restart:` policy, or a shutdown that cannot complete — s6 restarts just this
service, the grace period re-arms, and without a cap the container would be
halted on a loop indefinitely.

So after `GLUETUN_PF_NETNS_WATCHDOG_MAX_HALTS` attempts it stops trying, says
why, and leaves the port sync running:

```
[mod-gluetun-portforward] **** already halted 3 time(s) since this container started and it is still stranded; giving up ****
[mod-gluetun-portforward]   -> halting is plainly not recovering this container, so continuing would just restart it forever.
[mod-gluetun-portforward]   -> check it has 'restart: unless-stopped' (or 'on-failure'): without a restart policy the halt stops it for good.
[mod-gluetun-portforward]   -> the watchdog is now off until this container is restarted. The port sync carries on regardless.
```

The count is per **container start**, not cumulative: a halt that works gets you
a fresh container and a fresh budget, so normal gluetun restarts never use it up.
Only *failed* halts accumulate. A namespace that recovers on its own also hands
the budget back.

This is the one thing either mod writes anywhere — a single small file under
`/run`, because the count has to survive the halt, and the halt ends the process.

**How long it actually takes:** roughly **30–40 seconds** after gluetun goes
away, not `4 × 60`. A dead namespace also means gluetun's control server is
unreachable, and that path already retries every `GLUETUN_PF_RETRY_INTERVAL`
(10 s) for the first six attempts before relaxing to the full interval. Four
strikes land inside that fast window.

### What you will see

```
[mod-gluetun-portforward] netns watchdog         : armed, 4 strikes, 60s grace, halts with exit 70
...
[mod-gluetun-portforward] **** no non-loopback interface in /sys/class/net -- this container looks stranded in a dead network namespace (strike 1/4) ****
[mod-gluetun-portforward] **** ... (strike 4/4) ****
[mod-gluetun-portforward] **** halting the container so docker re-attaches it to gluetun's namespace (exit 70) ****
```

If the namespace comes back before the count runs out, it says so and resets:

```
[mod-gluetun-portforward] **** network namespace recovered after 2 strike(s); watchdog reset ****
```

### Things worth knowing before you turn it on

- **The halt is graceful.** s6 runs its full shutdown sequence, so qBittorrent
  gets a proper `SIGTERM` and writes its fastresume data before exiting. That is
  the advantage over an external `docker kill`, which loses it.
- **`docker ps` will look alarming for a moment.** Docker refuses to start a
  container whose `network_mode: service:` target is not running, so if gluetun
  is still starting the restart retries with backoff and you will see it flapping
  in `Restarting`. That is correct behaviour — the container cannot leak while it
  is stopped — but it looks like a crash loop, so do not panic and file a bug.
- **Two apps behind one gluetun both halt.** If you run this mod and the Plex one
  behind the same gluetun and arm both, they will halt and restart independently
  within a few seconds of each other. That needs no coordination and is fine; it
  just reads like a cascade in the logs.
- **A mod is only re-applied when the container is recreated**, not restarted. To
  pick this feature up:
  `docker compose up -d --force-recreate qbittorrent`.
- **Try `GLUETUN_PF_NETNS_WATCHDOG_DRY_RUN=true` first** if you want to see the
  detection without granting it the ability to stop anything.

## How it works

Each poll, in order:

1. **Is qBittorrent's WebUI answering?** If not, wait and retry. qBittorrent
   restarting under the mod is routine and costs nothing.
2. **Ask gluetun for the forwarded port.** `GET /v1/portforward`, falling back to
   the older `GET /v1/openvpn/portforwarded`.
3. **Read qBittorrent's live preferences** with `GET /api/v2/app/preferences`.
4. **Only if something differs**, one `POST /api/v2/app/setPreferences` carrying
   a form-encoded `json=` field — not a raw JSON body, which qBittorrent ignores.

Reading the real preferences every poll instead of trusting memory is what lets
the mod self-heal: change the port by hand in the WebUI, or restore a config from
backup, and it converges again on the next poll.

**When gluetun reports no port** — VPN down, renegotiating, or port forwarding
switched off — that arrives as a perfectly normal `HTTP 200` with port `0`. The
mod logs it once and **leaves qBittorrent alone**, then re-applies the port when
it returns, as described above.

## Verifying it works

```bash
docker logs qbittorrent 2>&1 | grep mod-gluetun-portforward
```

A healthy start looks like this:

```
[mod-gluetun-portforward] **** starting ****
[mod-gluetun-portforward] gluetun control server : http://localhost:8000
[mod-gluetun-portforward] qbittorrent            : http://localhost:8080
[mod-gluetun-portforward] qbittorrent auth       : none (relies on qBittorrent's localhost auth bypass)
[mod-gluetun-portforward] qBittorrent is answering on http://localhost:8080
[mod-gluetun-portforward] gluetun v3.41.2, using route /v1/portforward
[mod-gluetun-portforward] **** gluetun forwarded port: 54321 ****
[mod-gluetun-portforward] updating qBittorrent: listen_port 6881->54321 random_port true->false upnp true->false
[mod-gluetun-portforward] **** qBittorrent listening port is now 54321 ****
```

Then confirm in the WebUI under Tools → Options → Connection: **Port used for
incoming connections** should show the forwarded port, with "Use different port
on each startup" unticked.

The real test is whether peers can reach you. Give it a few minutes on an active,
well-seeded torrent before judging — an unreachable client still downloads, which
is exactly why this failure goes unnoticed.

## Troubleshooting

| Log line | What it means |
| --- | --- |
| `refused the request (HTTP 403 Forbidden)` | qBittorrent wants authentication. Tick the localhost bypass, or set a permanent password and pass it — the message spells out both. |
| `rejected the credentials in GLUETUN_PF_QBT_USERNAME/PASSWORD` | Wrong username or password. qBittorrent answers a bad login with HTTP 200 and the body `Fails.`, so this is detected from the body, not the status. |
| `waiting for qBittorrent to answer` | The WebUI is still starting, or `GLUETUN_PF_QBT_URL` points somewhere wrong. Check `WEBUI_PORT`. |
| `cannot reach gluetun's control server … connection refused` | gluetun is not running, or its control server is not listening. Check `HTTP_CONTROL_SERVER_ADDRESS` (default `:8000`). |
| `cannot reach gluetun's control server … timed out` | Either the hostname is wrong — docker's DNS makes that look like a timeout — or packets are dropped. On a shared bridge network gluetun needs `FIREWALL_INPUT_PORTS=8000`. |
| `401 Unauthorized on every known port-forward route` | gluetun auth. The mod prints the exact `config.toml` role to paste. |
| `gluetun reports no forwarded port yet` | Normal. VPN down or renegotiating; qBittorrent is left alone and the port is re-applied when it returns. |
| `re-applying … after a port outage` | Expected, and deliberate. See above. |
| `stranded in a dead network namespace (strike n/4)` | gluetun's container was restarted and took the namespace with it. Only appears with the watchdog on; after the last strike the container halts and Docker restarts it attached correctly. |
| `network namespace recovered … watchdog reset` | A false alarm that cleared on its own. Nothing to do. |
| `halting the container so docker re-attaches it` | The watchdog fired. If the container then stays down, it has no `restart:` policy — that is the missing half of the mechanism. |
| `DRY RUN: would halt the container now` | The watchdog would have acted but `GLUETUN_PF_NETNS_WATCHDOG_DRY_RUN` is on. Unset it to arm. |
| The container sits in `Restarting` after a halt | Docker will not start a container whose `network_mode: service:` target is down. It retries with backoff and settles once gluetun is up. Correct, if unnerving. |

## Limitations

- The mod owns `listen_port`, and `random_port`/`upnp` unless you opt out. It
  will overwrite manual changes to those on the next poll.
- It does not bind qBittorrent to the VPN interface. That is a separate
  leak-prevention concern, and with `network_mode: service:gluetun` there is no
  non-VPN route out of the container anyway.
- One qBittorrent per gluetun. Two clients behind one VPN would be handed the
  same forwarded port and fight over it.

## Building your own image

1. Fork or clone this repo. The published package name is composed from both
   directory levels — `mods/<app>/<mod>` becomes `<app>-<mod>` — so leaving this
   at `mods/qbittorrent/gluetun-portforward-mod` keeps it
   `qbittorrent-gluetun-portforward-mod`.
2. Set `LABEL maintainer` in the `Dockerfile` to your GitHub username.
3. Push to `master`. This mod's own workflow tests it, then builds and pushes to
   GHCR using the built-in `GITHUB_TOKEN` — no Docker Hub account and no PAT
   needed.
4. **Set the `qbittorrent-gluetun-portforward-mod` package's visibility to
   public** on the repo's Packages page. GHCR packages are private by default,
   and `/docker-mods` then gets a 401 pulling the manifest. This is the single
   most common "my mod doesn't load" cause.

Published tags:

| Tag | From | Notes |
| --- | --- | --- |
| `:latest` | `master` | What you want. |
| `:<commit-sha>` | `master` | Immutable pin of the above. |
| `:nightly` | `develop` | Changes before they reach `:latest`. |
| `:nightly-<tree-sha>` | `develop` | Immutable nightly pin. |
| `:<your-tag>` | any branch | A manual run with the **tag** field filled in. Publishes that tag alone. |

## Local development

All paths below are relative to this mod's directory
(`mods/qbittorrent/gluetun-portforward-mod`).

Unit tests for the parsing logic — no Docker, no VPN, no qBittorrent:

```bash
bash test/run_tests.sh              # with jq
NO_JQ=1 bash test/run_tests.sh      # exercises the sed fallbacks
```

They need bash 4+ for `declare -A` and `mapfile`. macOS ships bash 3.2, so on a
Mac run them in a container:

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt bash:5 sh -c 'apk add -q jq && bash test/run_tests.sh'
```

End-to-end smoke test — runs the real `run` script against Caddy stubs for both
gluetun and qBittorrent, and asserts on its log output and on the requests that
actually reached the stub. Thirteen scenarios covering the happy path, the
re-apply-after-outage behaviour, both authentication routes, wrong credentials,
every gluetun response shape, the netns watchdog staying off by default, and
SIGTERM handling:

```bash
bash test/smoke.sh
```

Before pushing:

```bash
shellcheck -x \
  root/etc/s6-overlay/s6-rc.d/svc-mod-qbittorrent-gluetun-portforward-mod/{run,finish} \
  root/usr/local/lib/mod-gluetun-portforward/netns-watchdog.sh \
  test/run_tests.sh test/smoke.sh

# s6 silently ignores non-executable service scripts, so this must print nothing
find . \( -name run -o -name finish -o -name check \) -not -perm -0111 -print
```

The netns watchdog lives once, in `shared/mod-gluetun-portforward/`, rather
than being copied into each mod. A mod is still a single-layer image, so the
Dockerfile assembles `root/` and the shared directory in a `FROM scratch`
*assembly* stage and the final stage takes the result in one `COPY --from`.
The build context is the repo root, which is what makes `shared/` reachable.

Two consequences worth knowing: editing that file changes every
gluetun-portforward mod's image at once, and this mod's workflow therefore
carries a `paths:` filter for `shared/mod-gluetun-portforward/**` so a change
there actually runs its tests. `ci/check-shared-files.sh` fails the build if
that filter goes missing.

## Credits

The gluetun side of this mod shares its logic with
[plex-gluetun-portforward-mod](../plex/gluetun-portforward-mod.md), and owes the
qBittorrent API shape to the example in the
[gluetun wiki](https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/vpn-port-forwarding.md).

## License

MIT.
