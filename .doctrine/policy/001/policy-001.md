# POL-001: DRY: no parallel implementation

## Statement

Every behaviour has one implementation. Before writing new code, look for
existing code that does the job, or nearly does. Extend or adapt it rather than
writing a second version beside it.

- **Production code.** Do not write a second path that does what an existing
  module, function or type already does, even a "slightly different" one.
  Generalise the existing one and migrate its callers in the same change.
- **Tests.** Extend `test/support` (fixtures, helpers, harnesses) instead of
  writing a local harness, a hand-built response or a copied helper in a test
  module. If a test needs something the support code lacks, add it there.
- **When duplication is deliberate,** for example an independent oracle in a
  test, or a boundary that must not share code, say why in a comment where
  the duplicate is written, and in the phase notes.

## Rationale

Agents write new code more readily than they find and adapt existing code.
Left unchecked, this produces agentic sprawl: near-duplicate helpers,
harnesses and code paths that drift apart, multiply the review surface, and
hide which version is authoritative. SL-001 reviews repeatedly caught workers
building parallel test harnesses (a local `first_post` re-running sync, and
hand-built responses duplicating `jmap_fixture`). Catching this at authoring
time is far cheaper than consolidating it later.

## Scope

This policy covers all source and test code in this repository, written by
humans, the orchestrator, or delegated workers. Worker briefs must name the
existing modules and support types to extend.

It does not apply to generated code, vendored dependencies, or throwaway
probes kept outside the tree (`probes.local.d/`).

## Verification

- **Design:** the design names the existing code each change extends.
- **Review:** every per-phase review checks for parallel implementation as a
  standing finding category. A finding is raised for any new helper, harness,
  fixture or code path that duplicates an existing one without the
  justification required above.
- **Audit:** slice conformance checks new files in `test/` and `src/` against
  the design's list of extended modules.

## References

- SL-001 notes: orchestration findings for PHASE-11 and PHASE-02 (parallel
  harnesses written by workers).
- Operator direction, 2026-10-27.
