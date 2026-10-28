In `doctrine design apply`, the top-level `acceptance` field is not a free-form note on the submission. In the `reviewing` stage the engine recorded it as the user's `design-accepted` act (authority user), alongside the declarations it was meant for.

Observed: SL-004 run, revision 31. A submission declaring 14 adversarial-lane section attestations (`att-adv-*`, reviewer adversarial) also carried a top-level `acceptance` citing RV-016. The engine logged `act_recorded cpa-design-accepted`. The user had not accepted the design. No verb retracts an act. It goes stale once the user's real `review-disposed` is recorded, because a user acceptance binds the disposition.

How to apply:
- Declare agent-lane (adversarial) attestations with no top-level `acceptance`.
- Send a top-level `acceptance` only in a submission recording what the user actually assented to, with the user's words as the basis.
- After any apply, read the event lines for an unexpected `act_recorded`.
