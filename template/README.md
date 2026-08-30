# Modname - Docker mod for imagename

[Release history](CHANGELOG.md)

One sentence saying what this mod does.

In imagename docker arguments, set an environment variable
`DOCKER_MODS=ghcr.io/quwisky/imagename-modname:1`

If adding multiple mods, enter them in an array separated by `|`, such as
`DOCKER_MODS=ghcr.io/quwisky/imagename-modname:1|linuxserver/mods:imagename-mod2`

Use `:edge` only to test verified, unreleased work from `master`.

---

## What it does

A paragraph on the problem and how the mod solves it. Say plainly what it
changes, and what it deliberately does not touch.

## Requirements

- The `linuxserver/imagename` image.
- Anything else that must be true for this to work.

## Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `MODNAME_ENABLED` | `true` | Set falsey to make the mod inert without editing `DOCKER_MODS`. |

Secrets also work with LinuxServer's `FILE__` convention, e.g.
`FILE__MODNAME_TOKEN=/run/secrets/token` — the baseimage materialises those
before any mod service starts. Make sure the file has no trailing newline.

## Verifying it works

```bash
docker logs imagename 2>&1 | grep mod-modname
```

## Troubleshooting

A table keyed by the exact log line the mod emits, so people can grep their logs
and land on the right row.

| Log line | What it means |
| --- | --- |
| `...` | ... |

## Limitations

What this mod cannot do, and what it will fight you over.

## License

MIT.
