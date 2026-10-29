# URL reputation signal: check mail link hosts against the operator's ControlD filters

Operator (2026-10-29): a script that checks the URLs in a mail against the
operator's ControlD account (which blocks tracking, malware, etc.) as another
signal of a malicious sender. Links are blocked anyway when a mail is opened,
but a host that ControlD refuses to resolve is a high-grade signal, more so
if ControlD says why (blocklist / category).

Operator (2026-10-29): test only the domain; never fetch the URL (that could
trigger tracking etc.).

Notes for shaping (inference, unverified):
- Source of hosts: raw `read` output, not the Jev state; `pii.strip` removes
  URL paths and queries, and the state carries no links. So this sits beside
  `classify` (or in a consumer), not inside it.
- Beacon risk: resolving an attacker's unique hostname through a forwarding
  resolver can confirm to its authoritative DNS that the mail was processed.
  Prefer a ControlD lookup that does not forward (an API or a query log of
  blocked hosts) over an ordinary DNS query. Whether ControlD exposes a
  "would this be blocked, and why" check needs research. Checking the
  registrable domain (eTLD+1) rather than the full host also defeats
  per-recipient subdomains; ControlD's verdict may differ by subdomain, so
  that is a tradeoff to weigh.
- Composes with mail-1: e.g. a blocked link host plus `deception_cues` or
  `agent_directive` is a strong bad signal.
- New outward reach (a network service, an account credential): needs its
  own slice and key ingress like DEC-038.
