# esqlite read-only URI facts (probed 2026-10-26, esqlite 0.10.0 via sqlight)

- `sqlight.open("file:" <> path <> "?mode=ro")` is honoured: SELECT works, any write fails with code 8 (`SQLITE_READONLY`, sqlight `Readonly`).
- A read-only open of a missing file fails with code 14 (`Cantopen`) and creates nothing. A plain `sqlight.open(path)` creates the file.
- Escape `%`, `?`, `#` in the path (`%` first) before building the URI.
- A read-only connection on a WAL store creates `-wal`/`-shm` beside it (the directory must be writable).
- esqlite reads filenames as Latin-1 (`enif_get_string(..., ERL_NIF_LATIN1)`): a non-Latin-1 path fails to open.
- `PRAGMA user_version` is transactional: set inside a transaction, it reverts on ROLLBACK.
- Test gotcha: `sqlight.close` rolls back an open transaction, so "dump unchanged after close" cannot tell a rollback from a leaked transaction. Keep the connection open and reuse it (the next `BEGIN` fails if a transaction leaked).
- The nix check sandbox has no `sqlite3` CLI; screwtape's `test/support/store_dump` is the in-process `.dump` equivalent (it also records `user_version`).
