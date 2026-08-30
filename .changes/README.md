# Change fragments

Every pull request that changes shipped runtime files must add one uniquely
named JSON file here. The release bot consumes these files into package-local
changelogs and one combined release pull request.

```json
{
  "summary": "Describe the user-visible outcome.",
  "packages": {
    "plex-gluetun-portforward-mod": "minor"
  }
}
```

Valid bump levels are `patch`, `minor`, `major`, and `none`. Use `none` only
with a concrete explanation for a runtime-input change that does not alter the
published behavior. A shared component can be declared once:

```json
{
  "summary": "Harden the shared namespace watchdog.",
  "shared": {
    "mod-gluetun-portforward": "patch"
  },
  "packages": {
    "universal-gluetun-netns-watchdog-mod": "minor"
  }
}
```

The shared bump expands to every Dockerfile consumer. Package overrides may
increase its severity but cannot lower it.
