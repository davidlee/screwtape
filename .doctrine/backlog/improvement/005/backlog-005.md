# Relax PII erasure slightly where it hides malice signals from Jev

malebolge SL-007 (operator, 2026-10-29) clamps what the mail agent sees to
what Jev was shown (malebolge DEC-048), and found text Jev never sees or
sees only stripped (malebolge inq-14):

- **Display names.** `classify_state` keeps only sender domains, so Jev
  cannot see impersonation such as `"PayPal Security" <x@evil.example>`:
  the display name is the classic phishing cue.
- **URL paths and queries** become `/[…]`, so a lookalike or directive-shaped
  path (`/login-verify-account`, `/ignore-previous-instructions`) is invisible.
- **Address local parts** become `[email]` in bodies.

Proposal: relax `pii.strip` and `classify_state` just enough to carry these
signals, for example a capped sender display name, and URL path tokens with
long digit runs and identifiers still erased. Weigh each against what it
sends to Jev (a third party), and against `mail-1`'s `deception_cues` and
`agent_directive` gaining signal (IMP-003 tunes those).

Consumer effect: malebolge caps display names at 64 bytes and accepts the
URL / local-part residue until this lands; it would then show Jev's view of
those fields, or tighten its invariant.

## Operator direction (2026-10-29)

Jev should see sender email addresses (local part included), display names
("titles"), and domains — the material for assessments such as
`hacker@wor.ldbank.com` (lookalike domain, suspicious local part). Take this
in the same slice as IMP-006, which already adds every address list to
`classify_state`.

Trade-off accepted in direction, to be confirmed at design: more personal
data leaves the machine for typesafe.ai (Jev's provider). Still open: which
address lists get full addresses vs domains only (recipients are the
operator and their correspondents), the display-name cap, and URL-path /
body local-part relaxation.

Malebolge needs no change for this (its DEC-050 64-byte display-name cap
stays valid, and could later be relaxed; DEC-077 anticipates it).
