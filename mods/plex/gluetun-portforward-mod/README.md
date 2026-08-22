# Gluetun port forward - Docker mod for plex

This mod keeps Plex's public remote-access port in sync with the port your VPN
provider forwards through [gluetun](https://github.com/qdm12/gluetun).

In plex docker arguments, set an environment variable
`DOCKER_MODS=ghcr.io/quwisky/plex-gluetun-portforward-mod:latest`

If adding multiple mods, enter them in an array separated by `|`, such as
`DOCKER_MODS=ghcr.io/quwisky/plex-gluetun-portforward-mod:latest|linuxserver/mods:plex-absolute-hama`

Nightly builds from `develop` are published as
`ghcr.io/quwisky/plex-gluetun-portforward-mod:nightly`. A container only
re-applies a mod when it is recreated, not restarted, so use
`docker compose up -d --force-recreate plex` to pick one up.

---

## What it does

Providers that support port forwarding hand out a **random high port**, and it
changes. ProtonVPN negotiates via NAT-PMP with a 60-second mapping lifetime that
gluetun refreshes every 45 seconds, and because the gateway picks the port,
almost every reconnect yields a different one. Plex has no idea any of this
happened: it keeps publishing whatever port it last announced to plex.tv, so
remote access quietly breaks — and Plex Relay silently takes over at capped
bandwidth, so it often *looks* like it still works.

The mod polls gluetun's control server and pushes the current port into Plex,
live, with no restart. In steady state it is silent; it logs when something
changes and when something is wrong.

It writes exactly three Plex settings, and only when one of them is actually
wrong:

| Setting | Value | Why |
| --- | --- | --- |
| `ManualPortMappingPort` | the forwarded port | The public port Plex announces. |
| `ManualPortMappingMode` | `1` | The "Manually specify public port" checkbox. Plex's docs are explicit that setting the port with this off is a **silent no-op**. |
| `PublishServerOnPlexOnlineKey` | `1` | The Remote Access master switch. Opt out with `GLUETUN_PF_MANAGE_REMOTE_ACCESS=false`. |

And it never:

- edits `Preferences.xml` (it is read once, read-only, to get the token)
- restarts Plex
- touches `customConnections` or `allowedNetworks`
- unpublishes or reverts your port when the VPN drops — it leaves the last value
  alone and waits

## Requirements

- The `linuxserver/plex` image. No extra packages are installed: `bash`, `curl`,
  `jq` and `sed` are already there.
- **A claimed Plex server.** The mod reads `PlexOnlineToken` from
  `Preferences.xml`, which only exists once the server is claimed. Until then it
  waits patiently and says so once.
- gluetun with `VPN_PORT_FORWARDING=on` and a provider that supports it: PIA,
  ProtonVPN, PrivateVPN or Perfect Privacy.
- gluetun's control server reachable from the Plex container.
- **`VPN_PORT_FORWARDING_LISTENING_PORT=32400` on gluetun.** See below — this one
  is not optional and the mod cannot detect it for you.

### The one setting people forget

gluetun forwards, say, `54321` on the VPN's public IP. Plex listens on `32400`.
Nothing connects those two unless you tell gluetun to redirect:

```yaml
- VPN_PORT_FORWARDING_LISTENING_PORT=32400
```

On current gluetun releases (v3.41.2 and earlier) that is the singular
`..._LISTENING_PORT`, default `0` meaning "no redirect". On gluetun `master` it
became `VPN_PORT_FORWARDING_LISTENING_PORTS` (plural), with the singular kept as
a retro key, so setting the singular form is correct on every version today.

Without it **everything the mod does still succeeds** — Plex reports the right
port, plex.tv accepts the announcement — and remote access still fails, because
inbound traffic on the forwarded port lands nowhere. It is the nastiest failure
mode here, which is why the mod prints a reminder on every start.

The mod deliberately does *not* try to verify the redirect: reading gluetun's
environment from another container is impossible, listing the NAT rule needs an
`iptables` binary and `NET_ADMIN` that the Plex container does not have, and
hairpinning to the VPN's public IP from inside the tunnel fails whether or not
the rule exists, so it would report false alarms.

> The gluetun wiki warns against `VPN_PORT_FORWARDING_LISTENING_PORT` for
> "software that publicly announces its port… as that software would not be
> aware of the publicly visible port and would be announcing the private port
> instead." That warning is correct, and it describes exactly the problem this
> mod removes: the mod tells Plex the *public* port explicitly.

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
      # Plex is published HERE, not on the plex service, because plex shares
      # this container's network namespace.
      - 32400:32400/tcp
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
      # --- port forwarding: all three lines matter ----------------------------
      - VPN_PORT_FORWARDING=on
      - VPN_PORT_FORWARDING_PROVIDER=protonvpn
      # REQUIRED. Redirects the forwarded public port to Plex's 32400. Without
      # it the mod publishes a port that nothing routes anywhere.
      # On gluetun master this is VPN_PORT_FORWARDING_LISTENING_PORTS (plural).
      - VPN_PORT_FORWARDING_LISTENING_PORT=32400
      # -----------------------------------------------------------------------
      - TZ=Europe/Amsterdam
    restart: unless-stopped

  plex:
    image: lscr.io/linuxserver/plex:latest
    container_name: plex
    # Share gluetun's network namespace. gluetun's control server is then at
    # localhost:8000 and Plex at localhost:32400.
    network_mode: service:gluetun
    depends_on:
      gluetun:
        condition: service_healthy
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Amsterdam
      - VERSION=docker
      - PLEX_CLAIM=claim-xxxxxxxxxxxxxxxxxxxx
      - DOCKER_MODS=ghcr.io/quwisky/plex-gluetun-portforward-mod:latest
      # Everything below is optional and shown at its default.
      # - GLUETUN_PF_CONTROL_URL=http://localhost:8000
      # - GLUETUN_PF_PLEX_URL=http://localhost:32400
      # - GLUETUN_PF_INTERVAL=60
      # - GLUETUN_PF_LOG_LEVEL=info
      # Only if gluetun's control server has an auth role configured:
      # - GLUETUN_PF_APIKEY=<same value as in /gluetun/auth/config.toml>
    volumes:
      - ./plex/config:/config
      - /path/to/media:/media
    devices:
      - /dev/dri:/dev/dri
    restart: unless-stopped
```

Two things about that file:

- **No `ports:` on the `plex` service.** Docker forbids it with
  `network_mode: service:`, and publishing `32400` on gluetun is also what makes
  local clients work.
- **Recreating `gluetun` orphans Plex's network namespace** until Plex is
  recreated too. `docker compose up -d --force-recreate` both of them together.
  If you only recreate gluetun, the mod will report `waiting for Plex to answer`,
  because from inside the dead namespace even `localhost` is gone. That log line
  is honest, but the fix is on the compose side.

## Environment variables

With `network_mode: service:gluetun` the defaults are already right, so adding
the mod to `DOCKER_MODS` and setting nothing else works. Everything here exists
to handle a deviation from that path.

### Core

| Variable | Default | Purpose |
| --- | --- | --- |
| `GLUETUN_PF_ENABLED` | `true` | Set falsey (`false`, `0`, `no`, `off`) to make the mod inert without editing `DOCKER_MODS`. The service is then brought permanently down, so changing this back needs a container recreate. |
| `GLUETUN_PF_CONTROL_URL` | `http://localhost:8000` | gluetun's control server. Use `http://gluetun:8000` if Plex is on a shared bridge network instead of gluetun's namespace — and then also set `FIREWALL_INPUT_PORTS=8000` on gluetun. Scheme optional, trailing slashes tolerated. |
| `GLUETUN_PF_PLEX_URL` | `http://localhost:32400` | Plex's base URL. |
| `GLUETUN_PF_INTERVAL` | `60` | Seconds between polls in steady state, clamped to ≥ 5. |
| `GLUETUN_PF_LOG_LEVEL` | `info` | `debug` adds a line per poll, including "already in sync". `info` logs only transitions and real changes. |

### gluetun authentication

Only needed if you have mounted an auth `config.toml` — see below.

| Variable | Default | Purpose |
| --- | --- | --- |
| `GLUETUN_PF_APIKEY` | *(empty)* | Sent as the **`X-API-Key`** header. gluetun has no `Authorization: Bearer` support. |
| `GLUETUN_PF_USERNAME` | *(empty)* | HTTP basic auth username. Ignored if `GLUETUN_PF_APIKEY` is set. |
| `GLUETUN_PF_PASSWORD` | *(empty)* | HTTP basic auth password. |

Both secrets work with LinuxServer's `FILE__` convention, because the baseimage's
`init-envfile` step materialises those long before this service starts:

```yaml
- FILE__GLUETUN_PF_APIKEY=/run/secrets/gluetun_apikey
```

Make sure the secret file has **no trailing newline** — the baseimage warns about
this, and gluetun compares the key exactly.

### Advanced

| Variable | Default | Purpose |
| --- | --- | --- |
| `GLUETUN_PF_PLEX_TOKEN` | *(empty)* | Explicit token, instead of reading `PlexOnlineToken` from `Preferences.xml`. Required if `GLUETUN_PF_PLEX_URL` points at a different host — the mod warns loudly if it does and this is unset, since it would otherwise use *this* container's token for someone else's server. |
| `GLUETUN_PF_PLEX_PREFS_FILE` | `/config/Library/Application Support/Plex Media Server/Preferences.xml` | Where to read the token from. |
| `GLUETUN_PF_PORT_INDEX` | `0` | Which port to publish when your provider forwards several — Perfect Privacy always returns three, ProtonVPN up to five. `0` is the lowest, which is also the one gluetun itself reports as `port`. Out of range falls back to `0` with a warning. |
| `GLUETUN_PF_MANAGE_REMOTE_ACCESS` | `true` | Also force `PublishServerOnPlexOnlineKey=1`. Set `false` if you deliberately keep Remote Access off and only want the port kept accurate; otherwise the mod re-enables it every poll and you cannot turn it off from the web UI. |
| `GLUETUN_PF_RETRY_INTERVAL` | `10` | Seconds between retries while waiting for prerequisites: Plex not answering, server not claimed, gluetun unreachable. Clamped to ≥ 2. |
| `GLUETUN_PF_TIMEOUT` | `10` | Per-request timeout. The connect timeout is fixed at 5 s. |

The minimum gap between writes, the 429 backoff curve and the endpoint list are
intentionally not configurable — they are correctness properties, not
preferences.

## Recovering from a gluetun restart (opt-in)

**Off by default.** This is the one feature here that can stop your container, so
it never arrives by surprise — nothing below happens until you set
`GLUETUN_PF_NETNS_WATCHDOG=true`.

### The problem

`network_mode: service:gluetun` joins gluetun's network namespace **by container
ID**. When the gluetun container *restarts* — not merely reconnects — that
namespace is destroyed and a new one is created. Docker never re-attaches Plex,
so it is left stranded in the dead one: `eth0` went with the veth pair, `tun0`
went with gluetun's tun device, and only `lo` remains.

The result is a container that is up, healthy-looking, and completely isolated.
Plex is unreachable (its ports are published on gluetun), nothing routes out, and
it stays that way until Plex's container is restarted — at which point Docker
re-resolves `network_mode` against gluetun's *current* namespace and everything
works again.

This is the same condition as the `waiting for Plex to answer` line in the table
below, seen from the other side.

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
  plex:
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

- **The halt is graceful.** s6 runs its full shutdown sequence, so Plex Media
  Server gets a proper `SIGTERM` and closes its library database cleanly. That is
  the advantage over an external `docker kill`, which risks leaving it corrupt.
- **`docker ps` will look alarming for a moment.** Docker refuses to start a
  container whose `network_mode: service:` target is not running, so if gluetun
  is still starting the restart retries with backoff and you will see it flapping
  in `Restarting`. That is correct behaviour — the container cannot leak while it
  is stopped — but it looks like a crash loop, so do not panic and file a bug.
- **Two apps behind one gluetun both halt.** If you run this mod and the
  qBittorrent one behind the same gluetun and arm both, they will halt and
  restart independently within a few seconds of each other. That needs no
  coordination and is fine; it just reads like a cascade in the logs.
- **A mod is only re-applied when the container is recreated**, not restarted. To
  pick this feature up: `docker compose up -d --force-recreate plex`.
- **Try `GLUETUN_PF_NETNS_WATCHDOG_DRY_RUN=true` first** if you want to see the
  detection without granting it the ability to stop anything.

## How it works

Each poll, in order:

1. **Is Plex answering?** If not, wait `GLUETUN_PF_RETRY_INTERVAL` and retry.
   Plex restarting under the mod is routine and costs nothing.
2. **Do we have a token?** If not, read `PlexOnlineToken` from
   `Preferences.xml`. If the server is not claimed yet, say so once and keep
   waiting — a container can legitimately sit unclaimed for weeks.
3. **Ask gluetun for the forwarded port.** `GET /v1/portforward`, falling back to
   the older `GET /v1/openvpn/portforwarded`.
4. **Compare against Plex's live settings** via `GET /:/prefs` — all three of
   them, not just the port.
5. **Only if something differs**, one `PUT /:/prefs` with all three at once.

Reading Plex's real state every poll instead of trusting memory is what lets the
mod self-heal: restore `/config` from a backup, roll Plex back, or untick the
checkbox in the web UI, and it converges again on the next poll.

Writes are deliberately rare, because Plex rate-limits its published-mapping
state with HTTP 429. Four independent guards bound them: only-on-change, a
10-second floor between writes, exponential backoff on 429 up to 15 minutes, and
a check that trips if Plex keeps returning `200` without the value actually
changing.

**When gluetun reports no port** — VPN down, renegotiating, or port forwarding
switched off — that arrives as a perfectly normal `HTTP 200` with port `0`. The
mod logs it once and **leaves Plex completely alone**. Remote access is broken
during the outage either way, and thrashing plex.tv would only risk a rate limit.

## Verifying it works

```bash
docker logs plex 2>&1 | grep mod-gluetun-portforward
```

A healthy start looks like this:

```
[mod-gluetun-portforward] **** starting ****
[mod-gluetun-portforward] gluetun control server : http://localhost:8000
[mod-gluetun-portforward] plex                   : http://localhost:32400
[mod-gluetun-portforward] Plex is answering on http://localhost:32400
[mod-gluetun-portforward] using Plex token from /config/Library/Application Support/Plex Media Server/Preferences.xml (never logged)
[mod-gluetun-portforward] gluetun v3.41.2, using route /v1/portforward
[mod-gluetun-portforward] **** gluetun forwarded port: 54321 ****
[mod-gluetun-portforward] updating Plex: ManualPortMappingPort 32400->54321 ManualPortMappingMode 0->1
[mod-gluetun-portforward] **** Plex public port is now 54321 ****
```

Then confirm it stuck:

```bash
docker exec plex grep -o 'ManualPortMappingPort="[0-9]*"' \
  "/config/Library/Application Support/Plex Media Server/Preferences.xml"
```

And in Plex: **Settings → Remote Access** should show the forwarded port and
"Fully accessible outside your network". While you are validating, consider
setting `RelayEnabled=0` — Relay silently masks a broken direct connection, so
with it on you cannot tell success from failure.

## Troubleshooting

Every failure path prints a distinctive line, so grep the log and find it here.

| Log line | What it means |
| --- | --- |
| `no Plex token yet - is this server claimed?` | `PlexOnlineToken` is not in `Preferences.xml`. Claim the server in the web UI, or set `PLEX_CLAIM` and recreate, or set `GLUETUN_PF_PLEX_TOKEN`. The mod keeps waiting. |
| `waiting for Plex to answer` | Plex is starting, restarting, or (with `network_mode: service:gluetun`) gluetun was recreated and took the network namespace with it. |
| `cannot reach gluetun's control server … connection refused` | gluetun is not running, or its control server is not listening. Check `HTTP_CONTROL_SERVER_ADDRESS` (default `:8000`). |
| `cannot reach gluetun's control server … timed out` | Packets are being dropped rather than refused. If Plex is on a separate docker network instead of gluetun's namespace, gluetun needs `FIREWALL_INPUT_PORTS=8000`. |
| `cannot reach gluetun's control server … could not resolve host` | With `network_mode: service:gluetun` use `http://localhost:8000`; on a shared bridge network use `http://gluetun:8000`. |
| `401 Unauthorized on every known port-forward route` | Genuine auth problem. The mod prints the exact `config.toml` role to paste. See below. |
| `none of '…' exist` | The control server answered but has neither endpoint. Usually `GLUETUN_PF_CONTROL_URL` points at the wrong port. |
| `gluetun reports no forwarded port yet` | Normal. VPN down or renegotiating; Plex is left untouched. |
| `Plex rejected our token … (401)` | The token rotated or the server was re-claimed. The mod drops its cached token and re-reads the file. Self-healing. |
| `Plex rate-limited the settings update (429)` | Backing off, up to 15 minutes. Nothing to do. |
| `Plex returned 400 Bad Request` | A preference name was rejected. Either a Plex API change or a mod bug — please open an issue with the logged query string. |
| `the setting is not sticking` | Plex returned `200` three times but the value did not change. Something else is rewriting these settings, or this Plex build ignores `PUT /:/prefs`. |
| `stranded in a dead network namespace (strike n/4)` | gluetun's container was restarted and took the namespace with it. Only appears with the watchdog on; after the last strike the container halts and Docker restarts it attached correctly. |
| `network namespace recovered … watchdog reset` | A false alarm that cleared on its own. Nothing to do. |
| `halting the container so docker re-attaches it` | The watchdog fired. If the container then stays down, it has no `restart:` policy — that is the missing half of the mechanism. |
| `DRY RUN: would halt the container now` | The watchdog would have acted but `GLUETUN_PF_NETNS_WATCHDOG_DRY_RUN` is on. Unset it to arm. |
| The container sits in `Restarting` after a halt | Docker will not start a container whose `network_mode: service:` target is down. It retries with backoff and settles once gluetun is up. Correct, if unnerving. |

## gluetun authentication

On gluetun v3.41.0 – v3.41.2, `GET /v1/portforward` is **publicly readable with
no credentials by default**, so most people need nothing here. gluetun logs an
"unprotected by default" warning about it; that default is removed on gluetun
`master`, and then you will need a role.

```toml
[[roles]]
name = "plex-portforward-mod"
routes = [
  "GET /v1/portforward",
  "GET /v1/openvpn/portforwarded",
  "GET /v1/version",
]
auth = "apikey"
apikey = "<docker run --rm qmcgaw/gluetun genkey>"
```

Mount that at `/gluetun/auth/config.toml` and set `GLUETUN_PF_APIKEY` to the same
value. Two traps, both of which cause most of the 401 reports:

- **List both routes.** The legacy route `301`-redirects to the new one, and the
  redirected request re-enters the auth middleware as a separate route. Covering
  only one of them breaks the fallback path.
- **Adding *any* role removes *all* of gluetun's public defaults.** The public
  role is only injected when the role list is empty. So the moment you mount a
  `config.toml`, every other route you were relying on — health checks, dashboard
  widgets, `/v1/publicip/ip` — starts returning 401 until you cover it too.
  `HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE` has the same effect.

The file is read once at startup, so restart gluetun after editing it. A typo is
a hard startup failure, not a warning.

## gluetun version compatibility

The response shape changed three times. The mod handles all of it automatically,
including picking the right endpoint.

| gluetun | Endpoint | Body |
| --- | --- | --- |
| ≤ v3.38.0 | `/v1/openvpn/portforwarded` | `{"port":N}` |
| v3.39.0 – v3.40.4 | `/v1/openvpn/portforwarded` | `0` ports → `{"port":0}`, `1` → `{"port":N}`, `2+` → `{"ports":[…]}` with **no `port` key** |
| v3.41.0 – v3.41.1 | `/v1/portforward` (legacy `301`s to it) | same conditional shape |
| v3.41.2+ | `/v1/portforward` | `{"port":N,"ports":[N]}`, always both |

One subtlety worth knowing if you are debugging: on **v3.39.1 – v3.40.4**,
`/v1/portforward` answers **401**, not 404 — no auth role can cover a route that
is not in gluetun's route table. The mod therefore treats a 401 as inconclusive
until it has tried every endpoint, and only then reports an auth problem. Six
gluetun releases behave this way.

## Provider notes

- **ProtonVPN** — NAT-PMP, 60-second mapping lifetime refreshed every 45 s, and
  the gateway chooses the port, so expect a new port after nearly every
  reconnect. The default 60-second poll is sized for this. Needs `+pmp` on the
  OpenVPN username or a PMP-enabled WireGuard key, and up to 5 ports via
  `VPN_PORT_FORWARDING_PORTS_COUNT`.
- **PIA** — the port, its signature and expiry are persisted to
  `/gluetun/piaportforward.json`, so you keep the **same port for 60 days**
  across reconnects and container restarts, as long as `/gluetun` is a persistent
  volume. Losing that volume is the usual cause of a surprise port change. Note
  that PIA's port forwarding is widely reported to work only for P2P traffic.
- **Perfect Privacy** — always returns **three** ports, derived from the tunnel
  IP. See `GLUETUN_PF_PORT_INDEX`.
- **PrivateVPN** — OpenVPN only, single port, tied to the assigned tunnel IP.

Remote access reality check: plex.tv actively probes the connection you announce,
so the forwarded port really must reach container port `32400`. Only the external
port may vary — the internal one is always `32400`.

## Limitations

- The mod owns those three settings and will fight manual changes to them. Use
  `GLUETUN_PF_ENABLED=false`, or `GLUETUN_PF_MANAGE_REMOTE_ACCESS=false` for just
  the Remote Access switch.
- One Plex per gluetun. Two Plex containers behind one gluetun would both publish
  the same forwarded port, but the redirect only reaches one of them.
- It does not manage `customConnections`. It normally does not need to: Plex's own
  traffic already exits through gluetun, so plex.tv sees the VPN's exit IP without
  anyone telling it. Only the *port* is invisible to Plex.
- It cannot verify that gluetun's redirect is actually in place. See above.

## Why not `VPN_PORT_FORWARDING_UP_COMMAND`?

gluetun can run a command in its own container on every new-port event, with
`{{PORT}}`, `{{PORTS}}` and `{{VPN_INTERFACE}}` templates. It is the right answer
for qBittorrent, and it is worth knowing about.

It is a poor fit here. The command runs inside gluetun, which has no `curl` and no
`jq` — only busybox `wget` — and no shell syntax is parsed, so anything
non-trivial has to be a bind-mounted script. More importantly it cannot read
`Preferences.xml` for the Plex token, cannot wait for Plex to actually be ready,
and fires exactly once per event: if Plex happens to be restarting at that
moment, or if someone later changes the setting by hand, nothing ever corrects
it. The polling design re-converges from any state, which is what makes it
self-healing.

## Building your own image

1. Fork or clone this repo. The published package name is composed from both
   directory levels — `mods/<app>/<mod>` becomes `<app>-<mod>` — so leaving this
   at `mods/plex/gluetun-portforward-mod` keeps it
   `plex-gluetun-portforward-mod`. Renaming either level renames the package and
   the workflow file with it.
2. Set `LABEL maintainer` in the `Dockerfile` to your GitHub username.
3. Push to `master`. This mod's own workflow,
   [`.github/workflows/mod-plex-gluetun-portforward-mod.yml`](../../../.github/workflows/mod-plex-gluetun-portforward-mod.yml),
   runs only when this directory changes; it tests, then builds `linux/amd64`
   and `linux/arm64` and pushes to GHCR using the built-in `GITHUB_TOKEN` — no
   Docker Hub account and no PAT needed.
4. **Set the `plex-gluetun-portforward-mod` package's visibility to public** on
   the repo's Packages page. GHCR packages are private by default, and
   `/docker-mods` inside the Plex container then gets a 401 pulling the
   manifest. This is the single most common "my mod doesn't load" cause.
5. Point `DOCKER_MODS` at `ghcr.io/<your-user>/plex-gluetun-portforward-mod:latest`.

Published tags:

| Tag | From | Notes |
| --- | --- | --- |
| `:latest` | `master` | What you want. |
| `:<commit-sha>` | `master` | Immutable pin of the above. |
| `:nightly` | `develop` | Changes before they reach `:latest`. |
| `:nightly-<tree-sha>` | `develop` | Immutable nightly pin. |
| `:<your-tag>` | any branch | A manual run with the **tag** field filled in. Publishes that tag alone, leaving `:latest` and `:nightly` untouched. |

Note that a plain `docker compose restart plex` reuses the cached mod and skips
re-applying it when the layer digest is unchanged. Use
`docker compose up -d --force-recreate plex` to pick up a new build.

## Local development

All paths below are relative to this mod's directory
(`mods/plex/gluetun-portforward-mod`).

Unit tests for the parsing logic — no Docker, no VPN, no Plex:

```bash
bash test/run_tests.sh              # with jq
NO_JQ=1 bash test/run_tests.sh      # exercises the sed fallback
```

They need bash 4+ for `declare -A` and `mapfile`. macOS ships bash 3.2, so on a
Mac run them in a container:

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt bash:5 sh -c 'apk add -q jq && bash test/run_tests.sh'
```

End-to-end smoke test — runs the real `run` script against Caddy stubs for both
gluetun and Plex, and asserts on its log output and on the requests that actually
reached Plex. Fifteen scenarios covering the happy path, every gluetun response
shape, auth failures, the `401`/`429`/`400` paths, port loss, multi-port
providers, the netns watchdog staying off by default, and SIGTERM handling. Needs
only docker, about two minutes:

```bash
bash test/smoke.sh
```

Interactive integration — same stubs, but bind-mounted into a real Plex container
so you can poke at it:

```bash
cd test
docker compose -f docker-compose.test.yml up -d
docker compose -f docker-compose.test.yml logs -f plex | grep mod-gluetun-portforward
```

Swap `stubs/Caddyfile.gluetun-ok` for `-zero`, `-multi`, `-legacy` or `-401` (and
`Caddyfile.plex` for `-401`, `-429` or `-400`) to drive each failure path, then
restart just that stub — the mod re-converges on its next poll.

The inner loop after editing `run`, no rebuild needed:

```bash
docker compose -f docker-compose.test.yml exec plex \
  s6-svc -r /run/service/svc-mod-plex-gluetun-portforward-mod
docker compose -f docker-compose.test.yml exec plex \
  s6-svstat /run/service/svc-mod-plex-gluetun-portforward-mod
```

Before pushing:

```bash
shellcheck -x \
  root/etc/s6-overlay/s6-rc.d/svc-mod-plex-gluetun-portforward-mod/{run,finish} \
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

Built on prior art from the qBittorrent side of the same problem —
[mjmeli/qbittorrent-port-forward-gluetun-server](https://github.com/mjmeli/qbittorrent-port-forward-gluetun-server),
[monstermuffin/qSticky](https://github.com/monstermuffin/qSticky) — and on
[danielewood/plexargod](https://github.com/danielewood/plexargod) and
[cetteup/update-plex-ipv6-access-url](https://github.com/cetteup/update-plex-ipv6-access-url)
for how to drive Plex's `/:/prefs` endpoint non-interactively.

## License

MIT.
