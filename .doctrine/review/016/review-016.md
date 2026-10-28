# Review RV-016 — design of SL-004

Adversarial-review ledger. Structured findings live in the sister
ledger toml; this prose companion carries the reviewer's framing.

## Brief

Raiser: codex. Hostile design review of SL-004, design-run revision 24.

Probe the classifier's real trust boundaries: attacker-controlled mail and
Jev replies, PII stripping and request bounds, credential ingress and crash
containment, typed output consumed under a schema id, stop/resume semantics,
and whether the proposed evaluation can settle the claims it gates. Check
the HTTP refactor and test reuse against POL-001, and fixture/evaluation
handling against POL-002. Accepted DEC-033 through DEC-038 are constraints;
challenge concrete contradictions and failure cases in their realisation.

Read the slice, materialised design, notes Harvest, research and both raw
threads, governing policies and decisions, relevant source/test/Nix seams,
and malebolge's scrubbed fixture provenance and envelope shapes. Verify API
claims against the local TypeSafe SDK and public primary documentation.
Use only synthetic values for counterexamples. Do not read private mail,
use credentials, call Jev, run provisioning, or modify any other artifact.

The user restricted writes to RV-016; no reviewer-cache priming or design-run
attestations are performed outside this ledger. Findings distinguish observed
source/spec contradictions from inferred consequences in an unimplemented
design. Raiser conclusion leaves disposition to the responder.
