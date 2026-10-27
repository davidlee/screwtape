# Review RV-009 — reconciliation of SL-002

Adversarial-review ledger. Structured findings live in the sister
ledger toml; this prose companion carries the reviewer's framing.

## Brief

<!-- Pre-reading + lines of attack: what this review is probing, the invariants
     it must hold the subject to, and where the bodies are likely buried. Seeded
     at `review new`; the reviewer fills it before raising findings. -->

Mode: **conformance** (post-implementation, self-audit; an independent
fresh-context Opus subagent raises the cross-phase findings). Surface: primary
checkout, `main` at df9e11a; whole delta 40048a6..df9e11a (nine phases).

Lines of attack:

- **Mechanical evidence.** `doctrine slice conformance SL-002` (undeclared /
  undelivered cells), `doctrine slice verify-vt SL-002`, `doctrine check gate`,
  `gleam format --check`, `just check`.
- **DEC-025 invariant.** After either path, the newest `max_messages`
  messages that pass the window filter equal a full sync's on a stable server,
  including the deletion backfill case found at design review.
- **DEC-026 path choice.** Prior discard (api_url, account, max_body_bytes);
  fallback triggers (no state, `cannotCalculateChanges`, `window_changed`,
  `too_many_changes`); summary `mode` and `fallback_reason`; the documented
  `cannotCalculateChanges` overspend.
- **Scope objective 4.** No duplicate body fetches: the no-change path sends no
  `Email/query` and no `Email/get` with ids (VH-1 inferred this live).
- **Cross-phase integration** that no phase review owned; README and
  `nix/module.nix` claims against the code; POL-001 (DRY: no parallel
  implementation) across the delta.
- **Carried items** (notes.md § Harvest → Open): Thread/get ids now sorted
  (supersedes an SL-001 runtime-sheet assumption), PHASE-02 delta tightened
  past foreign commit 0103779, CHR-004 remainder, RV-005's unrun verify round.


## Synthesis

**Closure story.** SL-002 delivers what its scope promised. Incremental sync
runs through `Email/changes`, with one pure merge (`screwtape/retain`) and
the M1 full path as fallback and correctness reference. All four fallback
triggers are reported as `mode` / `fallback_reason`. Retention
(`retain_messages`) is separate from the fetch window. Evidence at audit:
430 tests green (`just check`, `--warnings-as-errors`), `gleam format
--check` clean, `nix flake check` clean, `doctrine check gate` clean. VH-1 ran
live: consecutive real syncs took the incremental path. That they sent no
`Email/get` with ids is inferred, not observed (there is no request logging);
`second_sync_is_incremental_test` pins it.

An independent fresh-context reviewer checked 13 cross-phase invariants and
found them aligned: Prior discard, the `window_changed` triggers, fallback
names, the uncharged `cannotCalculateChanges` bytes, the page cap, the
no-change path, merge order, the delta fold, I-M3 on the incremental path,
I-M4 atomicity, I-M5 lossless reuse, CLI load order and README claims. It
raised two real test-evidence gaps, both confirmed here by mutation in a
scratch copy:

- F-5 (major): a surviving mutant could have stored the Prior's Email state
  on every fallback, so incremental sync would never resume after a
  `cannotCalculateChanges`. It is pinned now.
- F-6: every sync fixture shares one `receivedAt`, so the named I-M1
  backfill test passed even with destroyed ids ignored. The new
  `sync_fixture.newest_first` makes the deletion decisive.

Both were fixed red-first against the mutant. RV-005, the design ledger left
awaiting the raiser, was verified finding by finding against the code (F-4).

Considered and not raised: the README's after-upgrade claim. It holds by
composition: `window_json_test` pins the four-key string with
`"retain_messages":null`, and the `window_changed` tests cover a mismatched
`window_json`. The PHASE-02 delta was tightened past the foreign commit
0103779 (DEC-013), and conformance confirms it: the DEC-013 record is not
among the undeclared paths.

**Standing risks.**
- VT-3 (PHASE-03) stays FAIL in `verify-vt` because its keyword mandate is
  stale (F-1, tolerated). Clearing it is a plan act (`waived`, or an appended
  corrected VT), escalated to the operator.
- "No `Email/get` with ids" is not observable live without request logging.
- `api_url` is the server identity. A Fastmail `apiUrl` change costs one full
  refetch (bounded, accepted).
- Fixtures still order by the id tie-break except where `newest_first` is
  used. A future order-dependent test must use it.
- CHR-004's remaining items (POL-001 test-harness debt) stay open as backlog.

**Tradeoffs consciously accepted.**
- Every run rewrites the retained set; the cost is bounded by
  `retain_messages`.
- `cannotCalculateChanges` overspends the budget by up to about 2×
  `max_total_bytes`; this is documented.
- Retention covers configured mailboxes only.
- `receivedAt` ties at the boundary are ordered locally by id.
- The `.doctrine/` bookkeeping paths stay undeclared in conformance (F-2).

## Reconciliation Brief

### Per-slice (direct edit)
- F-2 — the selector registry is load-bearing:
  `doctrine slice selector add SL-002 --intent design-target` for
  `nix/module-eval.nix`, `test/screwtape/check_imports_test.gleam`,
  `test/screwtape/jmap/request_test.gleam`,
  `test/screwtape/jmap_fixture_test.gleam`,
  `test/screwtape/normalise_test.gleam`, `test/support/cli_fixture.gleam` and
  `test/support/snapshot_fixture.gleam`. Mirror the change in design.md's
  affected-surface prose where it lists targets. Leave `.doctrine/**`
  undeclared.
- F-3 — design.md § 5, sync-steps table, `threads` row: "`Thread/get` over the
  merged set's distinct thread ids, **sorted** (canonical, independent of merge
  order)". Note that this supersedes SL-001's runtime-sheet assumption A8
  (first-seen order).
- F-6 — design.md § 8 risk table, the `receivedAt` ties row: replace "the
  tests avoid boundary ties except one that pins the local order" with "sync
  fixtures share one `receivedAt` and order by the id tie-break; a test whose
  claim depends on order builds its emails with `sync_fixture.newest_first`".
- F-7 and F-8 are code fixes already made; nothing to reconcile.

### Governance/spec (REV)
- None. No ADR, policy, standard or spec is contradicted. POL-001 holds after
  F-8.

### Off-surface (operator)
- F-1 — PHASE-03 VT-3's keyword `opening_entries` is stale. The behaviour is
  tested at `opening_pairs`. Waiving it, or appending a corrected VT, is a plan
  act for the operator; it is not a reconcile edit.
- satan:RFC-020 D8 amendment draft — due at `/close` (cross-repo).

## Reconciliation Outcome

### Direct edits applied
- Selector registry (F-2): `doctrine slice selector add 2 --intent design-target`
  for the 7 test/nix paths. Conformance is now 11 undeclared (`.doctrine/`
  bookkeeping only, deliberately), 0 undelivered. Mirrored in the design.md § 10
  Code Impact table.
- design.md § 5.3, outcome table, `threads` row (F-3): the ids are now
  "sorted (canonical, independent of merge order; supersedes M1's first-seen
  order)".
- design.md § 8, the `receivedAt` ties row (F-6): it now states that fixtures
  share one `receivedAt` and order by id, so order-dependent tests use
  `sync_fixture.newest_first`.
- Following the SL-001 precedent (902bd7a), design.md is edited directly. The
  locked design-run record (`design.toml`) stays as the historical run.

### REVs completed
- None needed. No governance or spec item was in the brief.

### Withdrawn / tolerated
- F-1: tolerated. The PHASE-03 VT-3 keyword is stale, and the behaviour is
  tested at `opening_pairs`. A plan act is still the operator's: waive it, or
  append a corrected VT.
- F-4, F-5, F-7, F-8: code or ledger fixes made during the audit. Nothing to
  reconcile.

Reconcile pass complete; handoff to /close.
