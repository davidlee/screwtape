# CHR-002: Report htmerl 0.2.1 crashes upstream: tag-name EOF case_clause, unclosed table cell badmap, uppercase raw-text

<!-- Backlog item body — context, detail, links. The structured, queried fields
     live in the sister `backlog-NNN.toml`; this prose is free-form and is never
     structurally parsed (the storage rule). -->

Outward-facing (operator files it). Evidence: ASM-002 settlement body;
repros: `<a href='x'>l</a` (case_clause, htmerl_sax_utf8.erl:302),
`<table><tr><td>c` (badmap, dispatch ~2994), `<Script>if(a<b)x()</Script>`
(not raw text). Screwtape contains these via DEC-020; a fixed release would
let html_sax's catch become a pure safety net.
