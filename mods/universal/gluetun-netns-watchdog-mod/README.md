# Gluetun network-namespace watchdog - universal Docker mod

This mod recovers any LinuxServer container that is stranded when the Gluetun
container whose network stack it shares restarts.

Add it to the LinuxServer application container, not to Gluetun:

```yaml
environment:
  - DOCKER_MODS=ghcr.io/quwisky/universal-gluetun-netns-watchdog-mod:latest
```

Multiple mods are separated with `|`:

```yaml
environment:
  - DOCKER_MODS=ghcr.io/quwisky/universal-gluetun-netns-watchdog-mod:latest|linuxserver/mods:universal-apprise
```

Nightly builds from `develop` are published as
`ghcr.io/quwisky/universal-gluetun-netns-watchdog-mod:nightly`. A container only
applies a new mod layer when it is recreated, not restarted, so use
`docker compose up -d --force-recreate <service>` to pick up an update.

> Do not add this standalone mod to Plex or qBittorrent when using this
> repository's `*-gluetun-portforward-mod`. Those mods already contain the same
> watchdog; enable their `GLUETUN_PF_NETNS_WATCHDOG` option instead.

---

## What it does

`network_mode: service:gluetun` attaches a container to Gluetun's network
namespace. When Gluetun itself restarts, Docker creates a replacement namespace
for it but does not move containers that were already attached to the old one.
The application container remains running in a destroyed namespace with only
the loopback interface: it cannot route out, and the ports published on Gluetun
no longer reach it.

The watchdog looks for that exact state. After a startup grace period, if
`/sys/class/net` contains no interface except `lo` for four consecutive checks,
it gracefully halts its own container with a non-zero exit code. Docker's
restart policy then starts the container again and resolves
`network_mode: service:gluetun` against Gluetun's current namespace.

It deliberately does **not** test internet access, DNS, the VPN public IP,
Gluetun's health endpoint, or the presence of `tun0`. An ordinary VPN reconnect
can interrupt all of those while leaving `eth0` present. Acting on them would
turn a short tunnel reconnect into an unnecessary application restart; the
absence of every non-loopback interface is the narrower signal.

The scan is pure Bash against `/sys`. The mod installs no packages, opens no
ports, reads no credentials, mounts no Docker socket, and writes only a small
halt-attempt counter below `/run`.

### Safety behavior

- An absent, unreadable, or untraversable `/sys/class/net` is treated as
  healthy. Being unable to inspect it must never be interpreted as permission
  to stop the container.
- The 60-second startup grace and four consecutive failed scans avoid acting on
  transient initialization states.
- `GLUETUN_NETNS_WATCHDOG_DRY_RUN=true` exercises detection and logs the halt
  decision without stopping anything.
- The exit code defaults to 70, not zero, so `restart: on-failure` works.
- If s6 cannot complete the halt and merely restarts this watchdog service, it
  tries at most three times during that container start and then disarms itself
  instead of entering a hot loop.
- Shutdown is graceful: s6 stops the application and lets it flush databases,
  queues, and state before PID 1 exits.

## Requirements

- A current LinuxServer image using s6-overlay v3.
- The application container must use `network_mode: service:gluetun` or
  `network_mode: container:gluetun`.
- The application container must have `restart: unless-stopped` or
  `restart: on-failure`. Without a restart policy, the watchdog can stop the
  stranded container but Docker will not bring it back.
- Gluetun must itself come back. Docker cannot start a container whose
  `network_mode` target does not exist or is not running.

`depends_on` is optional and does not fix the runtime problem: it controls
Compose startup ordering, not reattachment after Gluetun restarts.

## Quick start

```yaml
services:
  gluetun:
    image: qmcgaw/gluetun:latest
    container_name: gluetun
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      # Publish the application's ports on Gluetun because it owns the shared
      # network namespace.
      - 8989:8989
    environment:
      - VPN_SERVICE_PROVIDER=protonvpn
      - VPN_TYPE=wireguard
      - WIREGUARD_PRIVATE_KEY=<your key>
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    network_mode: service:gluetun
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Budapest
      - DOCKER_MODS=ghcr.io/quwisky/universal-gluetun-netns-watchdog-mod:latest
    volumes:
      - ./sonarr:/config
      - ./media:/data
    restart: unless-stopped
```

The mod is enabled by being installed. Start in dry-run mode if you want to
observe its decision before allowing it to act:

```yaml
environment:
  - GLUETUN_NETNS_WATCHDOG_DRY_RUN=true
```

## Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `GLUETUN_NETNS_WATCHDOG_ENABLED` | `true` | Set falsey to leave the installed service permanently inactive. |
| `GLUETUN_NETNS_WATCHDOG_DRY_RUN` | `false` | Detect and log a dead namespace, but never halt the container. |
| `GLUETUN_NETNS_WATCHDOG_INTERVAL` | `15` | Seconds between interface scans; valid range 1–3600. |
| `GLUETUN_NETNS_WATCHDOG_GRACE` | `60` | Seconds after the watchdog starts before failed scans count. |
| `GLUETUN_NETNS_WATCHDOG_STRIKES` | `4` | Consecutive failed scans required before acting; minimum 1. |
| `GLUETUN_NETNS_WATCHDOG_EXIT_CODE` | `70` | Container exit status, from 1 through 255. Keep this non-zero for `on-failure`. |
| `GLUETUN_NETNS_WATCHDOG_MAX_HALTS` | `3` | Failed halt attempts allowed during one container start; `0` means unlimited. |

Falsey values are `0`, `false`, `no`, `off`, `disable`, and `disabled`, without
case sensitivity. Invalid numeric values are logged and replaced with their
defaults rather than terminating the watchdog.

## Verifying it works

The startup banner confirms the service is armed:

```bash
docker logs sonarr 2>&1 | grep mod-universal-gluetun-netns-watchdog
```

Expected output resembles:

```text
[mod-universal-gluetun-netns-watchdog] **** starting ****
[mod-universal-gluetun-netns-watchdog] interface directory : /sys/class/net
[mod-universal-gluetun-netns-watchdog] poll interval       : 15s
[mod-universal-gluetun-netns-watchdog] watchdog           : armed, 4 strikes, 60s grace, exit 70, gives up after 3 failed halt(s)
```

To test detection without disrupting the application, enable dry-run, recreate
the application container, then restart Gluetun. The application log should
count four strikes and finish with `DRY RUN: would halt the container now`.
Set dry-run back to `false` and recreate the application container when ready.

## Troubleshooting

| Log line | What it means |
| --- | --- |
| `disabled by GLUETUN_NETNS_WATCHDOG_ENABLED` | The mod is installed but explicitly disabled. Remove or set the variable to `true`, then restart the container. |
| `no non-loopback interface yet, but still inside the ... startup grace period` | The interface directory currently contains only loopback, but the watchdog is still waiting before counting strikes. |
| `looks stranded in a dead network namespace (strike n/N)` | No real network interface exists. If it persists through all strikes, the watchdog will halt unless dry-run is enabled. |
| `network namespace recovered after ... strike(s)` | A transient condition cleared before the action threshold. The strike count and failed-halt budget were reset. |
| `DRY RUN: would halt the container now` | Detection reached the threshold, but dry-run prevented the halt. |
| `halting the container so docker re-attaches it` | The watchdog fired. Docker should restart the application attached to Gluetun's current namespace. |
| `already halted ... and it is still stranded; giving up` | s6 did not complete earlier halt attempts. The watchdog disarmed itself for this container start to avoid a loop. |
| `watchdog helper is missing ...; not restarting` | The mod layer is incomplete or another mod overwrote its helper. Recreate the container and inspect the complete `DOCKER_MODS` list. |
| The container stops and stays stopped | It has no effective restart policy, or Gluetun is still down. Fix that and start the application container again. |
| Gluetun reconnects but the application does not restart | Correct behavior. A reconnect keeps `eth0`; the mod acts only when the whole shared namespace is destroyed. |

## Limitations

- This is not a VPN kill switch or a Gluetun health check. Gluetun's firewall is
  responsible for preventing traffic leaks while its tunnel is down.
- It cannot repair Docker's namespace attachment in place. Only restarting the
  application container makes Docker resolve the target again.
- It cannot restart itself through the Docker API and intentionally does not
  request the Docker socket. Recovery depends on the ordinary restart policy.
- It does not coordinate several dependents. Every LinuxServer container that
  shares Gluetun and needs automatic recovery must carry the mod independently.
- Do not combine it with another watchdog that acts on the same condition.

## Testing

The unit suite checks standalone-variable isolation, safe defaults and clamps,
the dead/live transition, halt bookkeeping, dry-run behavior, and the s6 finish
policy. The Docker smoke test drives the real longrun against healthy and fake
dead interface directories.

```bash
bash mods/universal/gluetun-netns-watchdog-mod/test/run_tests.sh
bash mods/universal/gluetun-netns-watchdog-mod/test/smoke.sh
```

The full helper safety matrix is also exercised by both existing Gluetun
port-forward mods because all three images ship the same file from `shared/`.

## License

MIT.
