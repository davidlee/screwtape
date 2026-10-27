# Fastmail Email/changes behaviour (probed live 2026-10-27, SL-002 inq-1, EVD-001)

- **Paging.** With `maxChanges` below the number of changes, each page returns an *intermediate* `newState` and `hasMoreChanges: true`. Call again with `sinceState = newState` to continue. Observed: J365090 → J365093 → J365097 with `maxChanges: 2`.
- **`cannotCalculateChanges`** is a method-level error (`["error", {type, description}]`) with two observed descriptions: `"invalid sinceState"` for a malformed state and `"outdated sinceState"` for an ancient one (`J1`). Treat both as the signal to fall back to a full sync. Don't branch on the description.
- **A mailbox move is an `updated` id,** not destroyed plus created. `Email/get` then shows the new `mailboxIds`. So window membership can be filtered locally from `updated`, and `queryChanges` isn't needed.
- One user action can advance the state by more than one (a single move: J365100 → J365103).
- Not exercised: an id appearing in more than one of created, updated and destroyed across pages. Union the pages defensively, letting destroyed win.
- Probe script: `probes.local.d/jmap/changes-probe.sh` (untracked; read-only; usage is in its header).
