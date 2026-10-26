# ASM-002: htmgrrrl's event API suffices for a text-extraction fold

<!-- Knowledge record body — context, detail, links. The structured, queried
     fields live in the sister `record-NNN.toml`; this prose is free-form and is
     never structurally parsed (the storage rule). -->


## Settlement (2026-10-26, PHASE-03/EX-1)

Validated for the claim as written: the event API suffices. Observed with
the pinned htmgrrrl 1.0.1 / htmerl 0.2.1 (latest on hex), orch erl probes:

- StartElement carries attributes (img alt available); EndElement for each
  start, unclosed p/li closed implicitly; entities decoded in Characters
  (`&nbsp;` → U+00A0, numeric refs, invalid refs → U+FFFD, unknown named
  entities left literal); Comment, StartCdata/EndCdata, StartDtd separate.
- Unparseable input (`</</`, `<p>ok</p></</`) returns Error(Nil).
- Element-name case is inconsistent (`HTML`, `BR` kept; `title`, `img`
  lowered): the fold must lowercase.
- `<SCRIPT>`/`<Script>` are not raw text: content tokenised as markup and
  following text nested inside the script element.
- `&&&` alone yields no Characters.

Not covered by the claim, and decisive for EX-2: htmerl **raises** rather
than returning Error on input ending inside a tag name (case_clause,
htmerl_sax_utf8.erl:302; 87 of 316 truncation offsets of a sample email)
and on an unclosed table cell, truncated or not (badmap). Handled by
DEC-020 (trim + catching html_sax wrapper).
