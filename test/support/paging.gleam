//// Test support: the one page walk both cursor suites use (PHASE-04, VT-1;
//// POL-001 — no parallel implementation).
////
//// A walk is a page function plus a cursor read off a page's last item, so the
//// store suite's `Oldest` walk and the CLI suite's `list --after` walk share
//// this loop and differ only in what a page is.

import gleam/list
import gleam/result

/// Walk `page` from `start` to the first empty page, collecting every item in
/// walk order: each next page starts from `next` of the last item collected. An
/// empty page ends the walk, so a walk of one page fewer, or a repeated row,
/// differs from the whole list. A walk that has collected more than `bound`
/// items stops there, so a cursor that never advances fails rather than hangs.
pub fn walk(
  from start: c,
  page page: fn(c) -> Result(List(a), e),
  next next: fn(a) -> c,
  bound bound: Int,
) -> Result(List(a), e) {
  walk_on(page, next, bound, start, [])
}

fn walk_on(
  page: fn(c) -> Result(List(a), e),
  next: fn(a) -> c,
  bound: Int,
  after: c,
  collected: List(a),
) -> Result(List(a), e) {
  use items <- result.try(page(after))
  let overrun = list.length(collected) > bound
  case list.last(items) {
    Error(Nil) -> Ok(collected)
    Ok(_) if overrun -> Ok(collected)
    Ok(last) ->
      walk_on(page, next, bound, next(last), list.append(collected, items))
  }
}
