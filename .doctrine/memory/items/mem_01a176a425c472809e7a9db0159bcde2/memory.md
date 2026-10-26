`gleam/dynamic/decode.dict(k, v)`: when a **value** fails to decode, the error path gains the **key** verbatim (stdlib `fold_dict` → `path_segment_to_string`, no quoting). Any key the server chose then lands in `Decode(path)` → stderr.

Probe (OTP 28.5, gleam_stdlib 1.x): session `"primaryAccounts":{"SENTINEL-KEY":5}` → `{decode,<<"primaryAccounts.SENTINEL-KEY">>}`.

- In screwtape every path goes through `decode.path`/`render`, which stops at the first segment that is neither an int index nor in `path_fields` (I1, D6). **A new decoder must add its field names to `path_fields`**, or its paths truncate at the last known field.
- Same class: never pass a server string (problem `type`, method-error `type`) into an `Error` unless it is in a fixed allowlist (RFC 8620 §3.6.1 / §3.6.2).
- A digits-only key still renders as `[n]` (digits only; accepted).

See [[mem.pattern.gleam.guard-spawn-monitor]] for the crash half of I1.
