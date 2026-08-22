# Discord notify - Docker mod for duplicati

This mod posts a colour-coded Discord embed after every Duplicati operation,
with the statistics, the destination and — when something went wrong — the
errors Duplicati actually reported.

In duplicati docker arguments, set an environment variable
`DOCKER_MODS=ghcr.io/quwisky/duplicati-discord-notify-mod:latest`

If adding multiple mods, enter them in an array separated by `|`, such as
`DOCKER_MODS=ghcr.io/quwisky/duplicati-discord-notify-mod:latest|linuxserver/mods:universal-cron`

Nightly builds from `develop` are published as
`ghcr.io/quwisky/duplicati-discord-notify-mod:nightly`. A container only
re-applies a mod when it is recreated, not restarted, so use
`docker compose up -d --force-recreate duplicati` to pick one up.

---

## What it does

Duplicati's built-in reporting is email or a raw HTTP POST of its result JSON.
Pointed at a Discord webhook, that second option delivers a wall of unformatted
JSON that nobody reads, so the failure you wanted to hear about arrives looking
exactly like the 300 successes before it.

This mod ships one script and asks Duplicati to run it after each operation. It
formats the result as a Discord embed: green for success, amber for warnings,
red for errors, and a skull for fatal, with the backup name in the title and the
statistics as fields. On anything worse than success it quotes the first few
error and warning lines in a fenced code block, so the message says what broke
rather than merely that something did.

It writes nothing, anywhere. Duplicati's databases, your job configuration and
`/config` are all untouched; the mod adds one file under `/usr/local/bin` and
makes one HTTPS request per operation.

### The destination is sanitised, always

`DUPLICATI__REMOTEURL` carries the backend's credentials inline — S3 secret
keys, B2 application keys, OAuth ids, ssh passphrases — and Duplicati's own
error messages quote that URL back at you in full. A webhook message is a
permanent record in someone's chat history, so the mod strips the query string
and any userinfo before displaying a destination, and applies a second
pattern-based pass over every log line it quotes:

```
s3://acme-offsite-backups/nas?auth-username=AKIA…&auth-password=wJal…
                    ↓
s3://acme-offsite-backups/nas
```

That is the one behaviour here worth calling a guarantee, and it has tests of
its own in both `test/run_tests.sh` and `test/smoke.sh`.

### The webhook URL stays out of the process table

The token in a webhook URL *is* the credential, and anything passed in a
command's arguments is readable from `/proc/<pid>/cmdline` by every process
running as the same user. So the URL is handed to `curl` through `--config` on a
pipe rather than as an argument, and the payload goes in on stdin. Neither ever
appears in `ps`, and neither is written to disk.

### It writes nothing to stderr, ever

Duplicati raises a warning against the operation for **any** output a
`--run-script` hook puts on stderr:

```
[Warning-...RunScript-StdErrorNotEmpty]: The script "..." reported error
messages: ...
```

A warning is not a failure, but decorating every backup with one because a
webhook was briefly unreachable is the same kind of harm. So everything this mod
prints — including its failures, and including `DISCORD_DEBUG` output — goes to
stdout, which Duplicati logs without complaint. `curl`'s own error output is
captured and re-emitted there too.

### It can never fail your backup

Duplicati treats a non-zero exit from `--run-script-after` as the operation
having failed, and reports it that way everywhere else you have notifications
configured. So this script exits 0 unconditionally — a webhook that is down, a
malformed result file, a DNS failure and an outright bug in the script all
produce a message on stderr and a zero exit.

## Requirements

- The `linuxserver/duplicati` image. The fixtures are written against Duplicati
  2.2's result format, and a real backup has been run end to end on the 2.3
  image — every field the embed shows was populated from 2.3's own result JSON.
  That the same fixtures and the same code cover both is the point of the
  result-file lookup being recursive rather than a fixed path: Duplicati has
  moved these fields between releases before, and the mod is built to survive it
  rather than to assume a version.
- **`SETTINGS_ENCRYPTION_KEY`**, at least 8 characters. Nothing to do with this
  mod: Duplicati 2.3 refuses to start without it, and the container never
  finishes initialising, so the mod never runs either.
- `jq` and `curl`. The `linuxserver/duplicati` image already carries both, so
  normally nothing is installed. If a future rebuild drops one, the mod appends
  it to `/mod-repo-packages-to-install.list` and lets the LinuxServer framework
  install it — nothing here calls `apt-get`. Without `jq` the mod still works,
  in a degraded form; see the `NO_JQ` row under Troubleshooting.
- A Discord webhook: **Server Settings → Integrations → Webhooks → New Webhook**,
  then **Copy Webhook URL**.
- **One manual step in Duplicati's web UI.** See the next section — the mod
  cannot do this for you.

## Quick start

```yaml
services:
  duplicati:
    image: lscr.io/linuxserver/duplicati:latest
    container_name: duplicati
    environment:
      - PUID=2109
      - PGID=2109
      - TZ=Europe/Budapest
      # Required by Duplicati 2.3+, and nothing to do with this mod: without it
      # the container never finishes starting. At least 8 characters.
      - SETTINGS_ENCRYPTION_KEY=<a long random string>
      - DOCKER_MODS=ghcr.io/quwisky/duplicati-discord-notify-mod:latest
      - DISCORD_WEBHOOK_URL_FILE=/run/secrets/discord_webhook
      - DISCORD_NOTIFY_ON=all
    volumes:
      - /tank/docker/duplicati/config:/config
      - /tank/docker/duplicati/backups:/backups
    security_opt:
      - no-new-privileges:true
    restart: unless-stopped
```

### The manual step

**Duplicati has to be told to run the script, and only you can tell it.**
Duplicati keeps its default options in `Duplicati-server.sqlite`, not in a
config file and not in an environment variable, and writing to that database
underneath a running Duplicati is not something a mod has any business doing.

In the web UI, go to **Settings → Default options** and add:

```
--run-script-after=/usr/local/bin/duplicati-discord.sh
--run-script-result-output-format=Json
```

The first is required. The second is optional but worth having: it makes the
result file JSON, which is what fills in the file counts, sizes and quota. Set
under **Default options** it applies to every job; set on a single job's
**Options** screen it applies to that job alone.

The mod prints these two lines into the container log at every start, so they
are always one `docker logs` away.

## Environment variables

Everything is optional except the webhook, and the webhook has three sources —
first match wins:

1. `DISCORD_WEBHOOK_URL`
2. `DISCORD_WEBHOOK_URL_FILE` — a file containing the URL, for Docker secrets,
   OpenBao and friends. A trailing newline is fine and is trimmed.
3. `/config/discord-webhook.url`

With none of them set the script runs and sends nothing, silently. That is
deliberate: the mod is often added to a container before anyone gets round to
creating the webhook, and a warning on every backup would be the only thing in
the log.

Note that *first match wins* is decided by the variable being **set**, not by it
working. `DISCORD_WEBHOOK_URL_FILE` pointing at a file the container cannot read
is an error, reported as one, and does not quietly fall through to
`/config/discord-webhook.url` — explicit configuration failing silently is how
you end up debugging the wrong thing.

| Variable | Default | Purpose |
| --- | --- | --- |
| `DISCORD_WEBHOOK_URL` | *(empty)* | The full `https://discord.com/api/webhooks/<id>/<token>` URL. |
| `DISCORD_WEBHOOK_URL_FILE` | *(empty)* | Read the URL from this file instead. |
| `DISCORD_NOTIFY_ON` | `all` | `all`, `warning` (Warning + Error + Fatal), or `error` (Error + Fatal). An unrecognised value is reported and treated as `all`. |
| `DISCORD_NOTIFY_OPERATIONS` | `Backup` | Comma-separated allowlist of operations — `Backup`, `Restore`, `Cleanup`, `Compact`, `Test`, `DeleteAllButN`. `*` for all of them. A name Duplicati does not use is reported but still honoured, so a future operation is not rejected. |
| `DISCORD_USERNAME` | `Duplicati` | The name the webhook posts under. |
| `DISCORD_AVATAR_URL` | *(empty)* | An avatar for the webhook message. |
| `DISCORD_MENTION_ON_ERROR` | *(empty)* | `<@123…>` for a user or `<@&123…>` for a role, prepended to the message on Error and Fatal **only**. |
| `DISCORD_HOSTNAME` | the container's hostname | Shown in the footer. Worth setting to the host's name if you run several. |
| `DISCORD_LOG_LINES` | `10` | How many error and warning lines to quote. Capped at 50. |
| `DISCORD_TIMEOUT` | `20` | curl's timeout, in seconds. |
| `DISCORD_TEST_ON_START` | `false` | Post a test message once, at container start, to prove the webhook works before you run a backup. |
| `DISCORD_DEBUG` | `false` | Print the assembled payload to stderr, where Duplicati's log picks it up. |

LinuxServer's `FILE__` convention works for any of these too, e.g.
`FILE__DISCORD_WEBHOOK_URL=/run/secrets/hook` — the baseimage materialises those
before any mod service starts. `DISCORD_WEBHOOK_URL_FILE` does the same job and
does not depend on the baseimage, which is why the example uses it.

## What the message looks like

| Result | Colour | Emoji |
| --- | --- | --- |
| Success | green | ✅ |
| Warning | amber | ⚠️ |
| Error | red | ❌ |
| Fatal | dark red | 💀 |
| Unknown | grey | ❔ |

The title is `<emoji> <backup name> — <result>`; the footer is
`<hostname> • Duplicati` with the operation's timestamp beside it. The fields
are whichever of these Duplicati actually reported:

Operation · Duration · Files examined / Added / Modified / Deleted ·
Size examined · Uploaded · Downloaded · Files uploaded · Quota used ·
Errors · Warnings · Destination · Source

**A field with no value is omitted rather than rendered as `N/A`.** Error and
warning counts are shown when non-zero, and on any non-success result they are
shown even at zero — "3 errors, 0 warnings" is information; "0 errors" under a
green tick is a row to scroll past.

## Checking the webhook without running a backup

Set `DISCORD_TEST_ON_START=true` and recreate the container. It posts one
message at start — in its own colour, with a bell rather than a result emoji,
so it cannot be mistaken for a backup outcome — carrying the two options you
still have to paste into Duplicati, and how to turn the test off again.

```yaml
      - DISCORD_TEST_ON_START=true
```

It ignores `DISCORD_NOTIFY_ON` and `DISCORD_NOTIFY_OPERATIONS` deliberately:
someone asking whether their webhook works wants an answer, not silence because
they also filtered to errors only. With no webhook configured it says so in the
container log rather than doing nothing quietly — the opposite of the
per-backup path, and right, because this runs once at start where you are
looking.

**It does not hold Duplicati up.** The oneshot that sends it is deliberately
*not* registered in `init-mods-end/dependencies.d/`, so nothing waits for the
request. Measured against the real image with the webhook pointed at a
blackholed address and `DISCORD_TIMEOUT=20`:

| | Duplicati answering | `[ls.io-init] done` |
| --- | --- | --- |
| test off | 2s | 2s |
| test on, Discord unreachable | **2s** | 21s |
| test on, if it *were* registered there | 22s | 22s |

So an unreachable Discord costs you nothing but a late init banner — s6 still
waits for every oneshot before printing it. Leave the test on if you like the
restart ping; it costs one HTTPS request per container start.

The oneshot drops to the same user Duplicati runs as before invoking the script,
so a test that passes really does prove the webhook file is readable by the
account that will read it later. Under `LSIO_NON_ROOT_USER`, where there is no
`abc` to drop to, it runs as-is.

You can also fire one on demand, without a restart:

```bash
docker exec duplicati /usr/local/bin/duplicati-discord.sh --test
```

## Verifying it works

```bash
docker logs duplicati 2>&1 | grep mod-discord-notify
```

A healthy start looks like this:

```
[mod-discord-notify] **** starting ****
[mod-discord-notify] **** one manual step is still needed ****
[mod-discord-notify]   Duplicati stores its default options in Duplicati-server.sqlite, so a mod
[mod-discord-notify]   cannot register itself. Open the web UI and add this under
[mod-discord-notify]   Settings -> Default options:
[mod-discord-notify]
[mod-discord-notify]     --run-script-after=/usr/local/bin/duplicati-discord.sh
```

`adding jq to the package install list` appears only on an image that does not
already have it, which the current `linuxserver/duplicati` does.

Then run any backup job. The message should arrive within a second or two of the
job finishing. If it does not, set `DISCORD_DEBUG=true` and look at the job's
log in the web UI under **Show log** — everything this script prints goes there,
not into `docker logs`, because Duplicati is what invokes it.

## Troubleshooting

| Symptom | What it means |
| --- | --- |
| Nothing happens at all, and the job log has no mention of the script | `--run-script-after` was never set, or has a typo. It is under **Settings → Default options**, and the path is exactly `/usr/local/bin/duplicati-discord.sh`. |
| `DISCORD_TEST_ON_START is set but no webhook is configured` | The startup test ran and had nothing to send to. Set one of the three webhook sources. |
| `no webhook configured; nothing to send` (with `DISCORD_DEBUG=true`) | None of the three webhook sources is set. The mod is installed and inert. |
| `DISCORD_WEBHOOK_URL_FILE=… is not readable` | The secret is not mounted, or not readable by the user Duplicati runs as. Check `PUID`/`PGID` against the file's owner. |
| `DISCORD_NOTIFY_ON='...' is not one of all\|warning\|error` | A typo. `errors` and `warn` are the common ones; the accepted values are exactly `all`, `warning`, `error`. Until fixed, every operation notifies. |
| `DISCORD_NOTIFY_OPERATIONS lists '...', which is not a Duplicati operation name` | A typo, usually a plural — `backups` for `Backup`. Nothing will ever be sent for that name. |
| `Discord rejected the webhook (HTTP 404)` | The webhook was deleted in Discord, or the URL is truncated. It must be the whole `https://discord.com/api/webhooks/<id>/<token>`. |
| `Discord rejected the webhook (HTTP 401)` | The token half of the URL is wrong. Copy it again from Discord. |
| `Discord returned HTTP 429` | Rate limited. The mod retries once, honouring `retry_after`, then gives up until the next operation. Several jobs finishing at the same instant is the usual cause. |
| `curl failed (exit 28)` | The request timed out. Raise `DISCORD_TIMEOUT`, or check the container's egress — `discord.com` has to be reachable. |
| `curl failed (exit 6)` | DNS. Common when the container is on a VPN network namespace whose resolver is not up yet. |
| `event is '', not AFTER` (with `DISCORD_DEBUG=true`) | The mod is not receiving Duplicati's variables at all. Fixed in this version: the script's shebang used to be `#!/usr/bin/with-contenv bash`, which **replaces** the environment and discarded every `DUPLICATI__` variable. If you still see it, the script on disk is stale — recreate the container so the mod re-applies. |
| The message arrives, but with no file counts or sizes | `--run-script-result-output-format=Json` is not set. Without it the mod falls back to scanning Duplicati's plain-text result, which carries far less. |
| The message is one flat block of text, not an embed | The `NO_JQ` fallback engaged: `jq` is not on `PATH`. It ships with `linuxserver/duplicati`, so this means either a stripped image or a failed package install — check the start-up log for `[pkg-install-init]` errors. Recreating the container re-runs the install. |
| The message is missing rows you expected | Discord caps an embed at 6000 characters and 25 fields. A backup with a very long name or source list has its fields trimmed to fit; `DISCORD_DEBUG=true` reports how many were dropped. |
| Everything works, but the backup is reported as failed | Not this mod. The script exits 0 unconditionally, and `test/smoke.sh` asserts that against a dead webhook, a 404, a 429 and a DNS failure. |

## Limitations

- **The mod cannot register itself.** See the manual step above. This is a
  Duplicati design decision, not an oversight here.
- **One webhook for the whole container.** Per-job webhooks would mean per-job
  configuration, which Duplicati only offers through the same options screen —
  set `--run-script-after` on a single job if you want to be selective, or use
  `DISCORD_NOTIFY_OPERATIONS`.
- **No message editing or threading.** Every operation is a new message.
- **Fields come from Duplicati's result file.** If Duplicati does not report a
  statistic for a given operation, no amount of work here will produce it — the
  row is omitted instead.

## Building your own image

1. Fork or clone this repo. The published package name is composed from both
   directory levels — `mods/<app>/<mod>` becomes `<app>-<mod>` — so leaving this
   at `mods/duplicati/discord-notify-mod` keeps it
   `duplicati-discord-notify-mod`.
2. Set `LABEL maintainer` in the `Dockerfile` to your GitHub username.
3. Push to `master`. This mod's own workflow tests it, then builds and pushes to
   GHCR using the built-in `GITHUB_TOKEN` — no Docker Hub account and no PAT
   needed.
4. **Set the `duplicati-discord-notify-mod` package's visibility to public** on
   the repo's Packages page. GHCR packages are private by default, and
   `/docker-mods` then gets a 401 pulling the manifest. This is the single most
   common "my mod doesn't load" cause.

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
(`mods/duplicati/discord-notify-mod`).

Unit tests — no Docker, no Duplicati, no network. `curl` is shadowed by a shell
function that captures the payload instead of sending it:

```bash
bash test/run_tests.sh              # with jq
NO_JQ=1 bash test/run_tests.sh      # the pure-bash fallback payload
```

They need bash 4+ for `declare -A` and `${VAR,,}`. macOS ships bash 3.2, so on a
Mac run them in a container:

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt bash:5 sh -c 'apk add -q jq && bash test/run_tests.sh'
```

End-to-end smoke test — the real script against a Caddy stub standing in for
Discord. The stub logs each request body verbatim, so the assertions are made
against the bytes that crossed the network rather than against what the script
believed it built. Eleven scenarios: the happy path, a fatal backup, credentials
quoted inside Duplicati's own error text, the no-jq fallback, each filter, a
webhook read from a file, a 429, a deleted webhook, an unreachable host, and the
startup test through its real init oneshot — including every truthy and falsey
spelling of `DISCORD_TEST_ON_START`:

```bash
bash test/smoke.sh
```

The interactive harness in `test/docker-compose.test.yml` runs the mod inside a
real `linuxserver/duplicati` against the same stubs; it is not run by CI.

Before pushing:

```bash
shellcheck -x \
  root/etc/s6-overlay/s6-rc.d/init-mod-duplicati-discord-notify-mod/run \
  root/etc/s6-overlay/s6-rc.d/init-mod-duplicati-discord-notify-mod-test/run \
  root/usr/local/bin/duplicati-discord.sh \
  test/run_tests.sh test/smoke.sh

# s6 silently ignores non-executable service scripts, so this must print nothing
find . \( -name run -o -name finish -o -name check \) -not -perm -0111 -print
```

### How the pieces fit

There are two s6 oneshots, and the split between them is the point.

The first appends `jq` and `curl` to `/mod-repo-packages-to-install.list` if
they are missing, and prints the manual step. It is registered in
`init-mods-package-install/dependencies.d/` rather than only depending on
`init-mods`, which is what guarantees the append lands *before* the install runs
— in the base image `init-mods-package-install` depends on `init-mods` and
nothing else, so without that drop-in s6-rc is free to run the two in either
order and the append can land after the install has already read the list.

The second sends the `DISCORD_TEST_ON_START` message, and depends on
`init-mods-package-install` — the other way round. It needs `jq` and `curl` to
exist, so it must run after the install the first one asked for. Doing both in
one oneshot would work on today's Duplicati image, which ships them already, and
fail on any image that does not — at exactly the moment someone is trying to
find out whether their webhook works.

Neither oneshot can fail. A oneshot that exits non-zero can block container
start-up, and an unreachable Discord must never do that.

Nothing needs to be supervised, so there is no longrun.

`s6-setuidgid abc` appears exactly once, in the startup-test oneshot, guarded
for `LSIO_NON_ROOT_USER`. The notification script itself never needs it —
Duplicati already invokes it as the right user — but the oneshot runs as root,
and a test that reads a `/config` webhook file as root would pass while the real
notification later failed. That is the one outcome a test like this must not
produce.

The test oneshot is also deliberately **absent** from
`init-mods-end/dependencies.d/`, unlike the first one. Registering it there is
what makes the container wait, and nothing should wait on a notification:
measured against the real image with the webhook blackholed and
`DISCORD_TIMEOUT=20`, being registered there delayed Duplicati answering by 22
seconds. Without it the app is up in 2 and only the init banner is late.

## License

MIT.
