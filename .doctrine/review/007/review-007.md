# Review RV-007 — code-review of SL-002

Adversarial-review ledger. Structured findings live in the sister
ledger toml; this prose companion carries the reviewer's framing.

## Brief

<!-- Pre-reading + lines of attack: what this review is probing, the invariants
     it must hold the subject to, and where the bodies are likely buried. Seeded
     at `review new`; the reviewer fills it before raising findings. -->

Subject: SL-002 PHASE-09 (incremental fallbacks, DEC-026), diff `9564d91..59be0ae`.
Raiser: a fresh Opus agent (`opus-reviewer`). Responder: Opus (`opus`).

Pin the code to: design § 5.2 (fallback_reason table; JMAP additions: match
by `request.method_name(EmailChanges)`, continue with the Client held before
the call) and § 5.4 (Choosing the path, Failure and retry, Budget);
plan.toml PHASE-09 EX-1..EX-4, VT-1, VT-2.

Lines of attack:
1. Fallback correctness: both reasons produce exactly the full-with-Prior
   path (refresh every stored id, opening Email state, Email/query runs).
2. Budget: cannotCalculateChanges bytes uncharged; page-cap spend charged;
   VT-2 arithmetic exact rather than loose.
3. EX-3: every other Email/changes error fails before the write.
4. Design quality: `Start`/`Scope`/`Changes` shapes, reason/mode as one
   source of truth, POL-001 (no second full-path builder).
5. Tests: behaviour, mutant-killing power, fixture growth.
