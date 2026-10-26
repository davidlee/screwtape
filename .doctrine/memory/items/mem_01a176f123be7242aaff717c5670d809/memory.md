Observed 2026-10-26 (SL-001 PHASE-03, ASM-002 probe; htmgrrrl 1.0.1 / htmerl 0.2.1, latest on hex):

- Input ending inside a tag name (`…</a`, `…<di`) → `case_clause` exception at `htmerl_sax_utf8.erl:302` (87 of 316 truncation offsets of a sample email). JMAP `maxBodyValueBytes` truncation hits this routinely.
- `<table><tr><td>c` (unclosed cell, truncated or not) → `badmap`.
- `htmgrrrl.sax` returns `Error(Nil)` only for some junk (`</</`); the above escape as exceptions, which under `guard` would fail a whole sync as `internal`.
- Other quirks: element-name case inconsistent (lowercase them); `<SCRIPT>`/`<Script>` not raw text; a leading `<style>`/`<script>` with no `<head>` makes htmerl put following bare text inside a synthetic `<head>` (so never skip `head` wholesale).

In screwtape: html_text must parse only via `screwtape/html_sax` → `screwtape_html_ffi:sax/3` (try/catch, reason discarded — it can hold input text), after trimming an unterminated trailing `<tag`. check-imports enforces the edge. Upstream report: CHR-002.
