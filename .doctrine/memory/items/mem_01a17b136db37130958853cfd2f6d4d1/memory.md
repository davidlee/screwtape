Observed 2026-10-27 (doctrine 0.47.0, SL-002 drafting).

- `doctrine design materialise` renders sections in the order they were created, not by id.
- One `design apply` batch with several new `sec-*` subjects creates them in lexical id order:
  `sec-10` sorted before `sec-5-2` and landed between §5.1 and §5.2.
- There is no section delete or reorder field in the payload contract.
- Remedy that worked: move the `<!-- doctrine:section sec-N -->` block in design.md by hand,
  `doctrine design adopt <SLICE> --dry-run --diff` (it reports "reordered"), then `adopt`, then `materialise`.
- Prevention: declare sections one batch per position, or use ids that sort in document order
  (e.g. zero-padded `sec-01`…`sec-10`).
