The quotient pi forms (`read`, `write`) have no network and no `curl`, and the
Jev credential (`~/.config/credstore.encrypted/screwtape.jev`) must stay out of
pi context. Any live `classify` against Jev (e.g. a VH probe) runs on the host
from the orchestrating session, e.g. the erlang-shipment under `systemd-run`
with the stored credential.

Operator ruling (2026-10-29): live Jev calls are allowed unattended ("it's like
1/3 of a cent"). Synthetic probe mail is hand-made outside the repo (POL-002);
record only sizes, token counts and the `jev_context` outcome.

Source: SL-005 notes.md § Implementation run, § VH-1 live probe.
