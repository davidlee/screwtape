# CHR-004: Consolidate duplicated test harnesses and prune weak tests (POL-001 debt)

Found by the SL-002 test-suite survey on 2026-10-27. The pi worker's survey is
at `.doctrine/slice/002/research/raw/test-survey.md`, and its citations were
spot-checked. SL-002 takes on any item its own tests touch. The rest is here.

## Duplication (POL-001)

- `cli_fixture.full_sync_script` (`test/support/cli_fixture.gleam:156`) hand
  re-scripts the full sync for `local_jmap`, in parallel with `sync_fixture`
  and `jmap_fixture`. It also has a private `inbox()` (`:188`) duplicating
  `sync_fixture.inbox`. `token_leak_test` `email_get_error_script` (`:489`)
  and `unstable_query_script` (`:506`) do the same. Build all of them from
  `jmap_fixture`.
- `client_test.gleam:55-72` and `jmap_fixture_test.gleam:46-56` define the
  same `ok`/`get`/`expect` wrappers over `fixture_send`. There are two session
  openers: `client_test:76` and `jmap_fixture_test:59`. Move both into
  `fixture_send`.
- `unwrap(Result(_, subprocess.Failure))` is copied three times:
  `cli_test:91`, `ffi_test:151`, `token_leak_test:643`. Move it into
  `subprocess`.
- `methodResponses` is hand-built in `client_test:393,411-421` and
  `token_leak_test:216,498`, although `jmap_fixture.responses` and
  `error_entry` exist.
- `store_test.written:73` and `read_snapshot_test.written:180` are the same
  helper.
- `local_jmap.Reply` framing is built three ways: `transport_test:71,86` and
  `local_jmap_test:66`.

## Weak or duplicate tests

- `jmap_fixture_test:84,97,111,118,125` check only that each built document
  decodes, plus the response name. Strengthen them or drop them.
- `sync_test:629,638` duplicate `client_test:346,353`, the opening-response
  errors.
- `cli_test:1097,1103,1112` are three copies of one store-version refusal.
  Fold them into one table.
- `token_leak_test`: the 11 `run_failing_scenario` cases each spawn the
  shipment as a subprocess and a TLS server, and every one is also asserted
  in process (`:373-400`). Collapsing them to one or two shipment runs is the
  largest wall-clock saving in the suite.
- `skeleton_test:67` is a TLS positive control that the `transport_test` and
  `local_jmap` tests now cover.

## Guard

- `jmap_fixture.opening_entries` (`:327-346`) zips `request.opening`'s call
  names against a hard-coded list of three argument sets. A fourth opening
  call would silently truncate the zip. Assert that the lengths match.
- **Done in SL-002 PHASE-03:** `opening_entries` now pairs through
  `jmap_fixture.opening_pairs` (`list.strict_zip`), which fails on a length
  mismatch; pinned by `jmap_fixture_test`. The other items stay open.
