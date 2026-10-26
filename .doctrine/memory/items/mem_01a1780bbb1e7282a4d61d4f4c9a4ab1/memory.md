Pattern used for SL-001 invariant I8 (each read verb's output comes from one committed snapshot).

- Seam: the reader carries an `after_select: fn() -> Nil` hook that `select` calls after every query (`store.open_reader_with`, @internal; production passes a no-op). `cli.run_with` injects the reader opener so whole verbs run hooked.
- Test: write snapshot A; the hook opens a second connection and commits snapshot B on every call (idempotent, so no counter); assert the verb's output equals its output on A; then assert a plain read sees B (the commit really happened). Under WAL the writer commits beside the open reader without blocking.
- Control: make `store.read` skip BEGIN/COMMIT (per-query autocommit). Every hooked test must go red.
- Sharp edge: the test only discriminates if the read issues more than one select. A single join would pass under autocommit too, so keep the per-relation selects (`query.message` documents this).