# Fixtures

Duplicati result files as `--run-script-result-output-format=Json` writes them,
trimmed to the fields this mod reads plus enough of their real surroundings to
be a fair test.

| File | Stands for |
| --- | --- |
| `success.json` | A clean nightly backup. Every statistic present, quota reported, no log entries. |
| `warnings.json` | `ParsedResult: Warning`. The warning strings deliberately contain a double quote and a backslash, which is what breaks a payload assembled by string concatenation. |
| `error.json` | `ParsedResult: Fatal`, with a multi-line backend exception and an embedded stack trace. |
| `credentials.json` | An S3 key and an ssh passphrase, present both in the destination URL and quoted back inside Duplicati's own error messages. Nothing from here may reach the payload. |

Two shapes matter beyond the values:

- The statistics are split between the top level and `BackendStatistics`, and
  `BackendStatistics` repeats `MainOperation`, `ParsedResult` and `Duration`
  with different values. That is what the recursive-descent lookup has to get
  right — it must take the shallowest match, not any match.
- `Duration` is a .NET `TimeSpan`, not a number of seconds.
