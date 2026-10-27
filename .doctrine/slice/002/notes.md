# Notes SL-002: Screwtape M2: minimal incremental sync

Durable per-slice scratchpad — tracked in git. The place to lift anything from a
disposable phase sheet (`.doctrine/state/.../phase-NN.md`) that must survive
`rm -rf` before the slice close-out audit harvests it.

## Harvest
<!-- single-copy: updated in place each harvest; ids only, never restated content -->
fresh-as-of: 2026-10-27 · ready (plan materialised, PHASE-01 next) · 176932c

### Produced
- RV-005 hostile pass (Codex) disposed, integrated; design run locked rev 37 (8173079)
- DEC-024 accepted; DEC-024/025/026 amended per RV-005 (8173079, 176932c)
- plan.toml/plan.md: 9 phases, order 01-02-03-04-05-08-06-09-07; revised after a pi plan review (68f52ce..5b4e7e7)
- POL-001 · EVD-001 · DEC-025 (supersedes DEC-022) · DEC-026 (supersedes DEC-023) · CHR-004 · design.md (sec-1..sec-10)
- no code yet; no gate run needed

### Learned
- mem.fact.jmap.fastmail-email-changes — EVD-001's Fastmail Email/changes behaviour
- mem.fact.doctrine.design-section-order — design section ordering

### Open
- RV-005 — optional raiser verify/contest round (Codex thread resume) not run
- api_url as server identity — a Fastmail apiUrl change would cost one full refetch (see § Further review passes)
- satan:RFC-020 D8 amendment draft (no queryChanges; query-driven membership; retention) — at close
- research/ untracked and drifted (`doctrine slice research 2`) — operator to decide
- CHR-004 — SL-002 absorbs only the opening_entries guard (PHASE-03 VA-2)

## Design triage (2026-10-27, exploring)

**Constraining governance:**
- POL-001 (DRY, required).
- DEC-007: the schema is M2-ready.
- DEC-008: one atomic write per run.
- ISS-001: the Email and Thread states are taken by the opening request.
- satan:RFC-020 D7 and D8, and OQ-10 and OQ-11. These are evidence, not
  binding.

**Shaping decisions already made (operator, 2026-10-27):**
- Option B: incremental sync through `Email/changes`, with no `queryChanges`
  and no `Mailbox/changes`.
- `retain_messages` is separate from the fetch `max_messages`.
- The full path fetches the `Email/query` ids together with the stored ids.
- One pure merge serves both paths, and every commit goes through the
  unchanged `write_snapshot`.
- The fallback triggers are: no stored state, `cannotCalculateChanges`, a
  `window_json` mismatch, and `hasMoreChanges` still true at the page cap.
- Phases stay small, each phase is reviewed, and test discipline is strict.

**Open questions:** these are the run's inquiries, listed under the design
run (`doctrine design show --format prompt 2`).

**Risks:**
- The `Email/changes` semantics (research J1–J7) are recalled from the RFCs,
  not probed. The biggest is J5: a mailbox move must be reported as an Email
  update.
- `receivedAt` ties at the retention boundary.
- A write, load and rewrite round trip must leave the store unchanged.

**Assumptions:**
- Rewriting the whole retained set on every run is cheap: about 12 KB per
  message, all local.
- Fastmail keeps its change log long enough that `cannotCalculateChanges` is
  rare.

## GPT design review (2026-10-27, inquiring)

Informal critical review by Codex (gpt-6.1-sol, high effort) of DEC-022..024,
EVD-001, the inquiry notes, the scope, the research and the sync/store/config
code. Eight findings, each verified against the code and adjudicated
(`/feedback`); the operator accepted the dispositions.

- **Blocker (integrated):** local window selection never backfilled after a
  deletion (store `[A,B]`, server `[A,B,C]`, delete A → incremental `[B]`,
  full `[B,C]`). Retention only postpones it. With `retain_messages` set,
  "newest `max_messages`" also included messages past `max_age_days`. The
  research refresh's "count-capped divergence no longer applies" was wrong;
  the research file is left as is (untracked, operator to decide).
- **Redesign:** `Email/query` decides window membership and `Email/changes`
  decides which stored ids get a light refresh. A run with no changes skips
  the query. DEC-025 supersedes DEC-022 (invariant over the window filter);
  DEC-026 supersedes DEC-023. This also removes body fetches for changed
  messages outside the window, and sets a finite `maxChanges`.
- **Integrated (minor):** the `Prior` is discarded when the account or
  `max_body_bytes` differs; resolved mailbox ids join `window_json` as a
  fallback trigger; a no-change run carries the previous query record.
- **Contested prescription:** the `cannotCalculateChanges` bytes are dropped
  from the budget (verified: `client.gleam:103-114`, `decode.gleam:711`).
  Accepted as a documented bounded overspend (≤ about 2× `max_total_bytes`)
  instead of changing the client API.
- **Tests (inq-8 revised):** explicit expectations beside the comparison
  tests; generalise `expect_unchanged` (`sync_fixture.gleam:372`).
- Codex's full output: the session scratchpad `codex-out.json` (not kept).
- Next: sufficiency-accepted is again the operator's act, then drafting.

## Further review passes (2026-10-27, reviewing, after RV-005)

RV-005 (hostile pass, Codex as raiser on a fresh thread) is concluded and every
finding is disposed on the ledger; dispositions and repairs live there
(`doctrine review show RV-005`), not here. DEC-024/025/026 were amended to
match.

What a further pass would probe, if the operator wants one:

- the raiser's verify/contest round on RV-005 (resume the same Codex thread),
  chiefly the partly contested F-6 and the declined tests in F-2/F-3;
- whether `api_url` is a stable enough server identity (Fastmail could change
  its `apiUrl` without a server change; the cost would be one full refetch).

Otherwise none is needed: the remaining uncertainty is runtime behaviour
(concurrent changes, budget arithmetic), which the § 9 tests and the live check
settle better than another reading.
