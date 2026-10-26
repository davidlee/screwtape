# JMAP /query and /get response semantics (RFC 8620 § 5.1, § 5.5; applied in SL-001 PHASE-05)

- `/query` returns `total` only when the request sets `calculateTotal: true`. Paging that stops at "position reaches total" must ask for it; screwtape's decoder treats a missing `total` as `Decode("total")`.
- `/query` returns `limit` only when the server enforced a different limit from the one requested (a clamp). After you request exactly the clamped value, the server may stop echoing it. So keep the clamp sticky across pages: `option.or(page.limit, previous_clamp)`. Re-deriving it from each page re-learns it every other page.
- A page shorter than the requested limit but equal to the clamp is not a short page. The effective page size is the response `limit` when present, else the request's.
- `/get` must answer every requested id in `list` or `notFound`. A response that drops an id, or returns one that wasn't asked for, is a server fault. sync fails with `Decode("notFound")` / `Decode("list")` rather than silently losing or adding a message (I3).
- `ids: []` is a valid `/get`. It returns no objects but does return the type's `state`; an empty window uses it so every type gets a state.
- Unverified against Fastmail until the live run (PHASE-09).
