<!-- raw thread output: Fastmail JMAP facts (RFC-020 OQ-9, Fastmail half).
     Producer: Claude subagent (general-purpose, web), 2026-10-26. Verbatim. -->

## Q1: Fastmail API tokens, scopes, read-only

- **Creating a token.** Go to Settings → Privacy & Security → "Connected apps & API tokens" → Manage API tokens → New API token. You choose "JMAP or MCP", pick scopes, then copy the token, because "you will not be able to see it again". "API tokens are not available to users on Basic subscription plans." https://www.fastmail.help/hc/en-us/articles/5254602856719 [primary]
- **JMAP scopes.** Each scope is a separate checkbox:
  - "Read-only access" ("You will be able to download and view your data, but your data cannot be changed")
  - "Email" ("download, modify, and permanently delete your mail")
  - "Email submission" (requires Email)
  - "Contacts and contact groups"
  - "Masked Email"

  Source: same page [primary]. Read-only is therefore its own scope, not a per-scope toggle. Inference: a read-only mail-sync token probably selects "Read-only access" alone, or with Email. How "Read-only access" combines with "Email" is not documented.
- **Capability URIs Fastmail lists:** `urn:ietf:params:jmap:core`, `urn:ietf:params:jmap:mail`, `urn:ietf:params:jmap:submission`, `urn:ietf:params:jmap:vacationresponse`, `urn:ietf:params:jmap:contacts`, `https://www.fastmail.com/dev/maskedemail`. https://www.fastmail.com/dev/ [primary]
- **Effect of a read-only token on the session object: not documented by Fastmail.** The spec defines Account `isReadOnly`: "This is true if the entire account is read-only." (RFC 8620 §2, https://www.rfc-editor.org/rfc/rfc8620.html#section-2 [primary]). A third-party sample session made with a full-access token shows `"isReadOnly": false` (https://github.com/joelparkerhenderson/demo-fastmail-api-jmap [secondary]).
- **Error on a write attempt: not documented by Fastmail.** The spec gives two candidates:
  - `accountReadOnly`: "This method modifies state, but the account is read-only" (RFC 8620 §3.6.2 [primary])
  - `forbidden`: "would violate an Access Control List (ACL) or other permissions policy" (§3.6.2 [primary])

  Inference: the program should treat either as "token lacks write", and M1 needs neither.

## Q2: Session and auth

- **Session URL:** `https://api.fastmail.com/jmap/session`. Auth header: `Authorization: Bearer {token}`. https://www.fastmail.com/dev/ [primary]
- **URLs in the sample session** (third-party sample, https://github.com/joelparkerhenderson/demo-fastmail-api-jmap [secondary]):
  - `apiUrl`: `https://api.fastmail.com/jmap/api/`
  - `uploadUrl`: `…/jmap/upload/{accountId}/`
  - `downloadUrl`: `https://www.fastmailusercontent.com/jmap/download/{accountId}/{blobId}/{name}?type={type}`
  - `eventSourceUrl`: `…/jmap/event/`

  Inference: always read `apiUrl` from the session; never hard-code it.

## Q3: Request caps

- **Fastmail does not document these.** Spec definitions and suggested minimums are in RFC 8620 §2 [primary]:
  - `maxSizeRequest` ≥ 10,000,000
  - `maxCallsInRequest` ≥ 16
  - `maxObjectsInGet` ≥ 500
  - `maxObjectsInSet` ≥ 500
- **Values in the third-party sample, undated, so not authoritative** (https://github.com/joelparkerhenderson/demo-fastmail-api-jmap [secondary]):

  | Field | Sample value |
  |---|---|
  | `maxSizeUpload` | 250,000,000 |
  | `maxConcurrentUpload` | 10 |
  | `maxSizeRequest` | 10,000,000 |
  | `maxConcurrentRequests` | 10 |
  | `maxCallsInRequest` | 50 |
  | `maxObjectsInGet` | 4096 |
  | `maxObjectsInSet` | 4096 |
  | mail `maxMailboxesPerEmail` | 1000 |
  | mail `maxSizeAttachmentsPerEmail` | 50,000,000 |
  | mail `maxSizeMailboxName` | 490 |
  | mail `maxMailboxDepth` | null |
  | mail `emailQuerySortOptions` | receivedAt, from, to, subject, size, header.x-spam-score |

- These must be read from the live session at runtime.

## Q4: Rate limits

- **Fastmail documents no API rate limits.** The only mention is that MaskedEmail/set create may return "A standard JMAP rateLimit SetError". https://www.fastmail.com/dev/ [primary]
- **What the spec says:**
  - A request may be rejected "due to rate limiting" (RFC 8620 §3.6 [primary]).
  - The `limit` request-level problem must carry a `"limit"` property naming the limit (§3.6.1 [primary]).
  - `rateLimit` is a /set SetError (§5.3 [primary]).
  - HTTP 429 appears only in the push section: "A '429' (Too Many Requests) response MUST cause the JMAP server to reduce the frequency of pushes" (§7.2 [primary]).
- Unknown: whether Fastmail sends 429 or `Retry-After` on `apiUrl`.

## Q5: Changes, queryChanges, state

- **Fastmail support for `Email/queryChanges`: no current documentation found.**
  - 2018 cyrus-devel thread: Cyrus (Fastmail's backend) refused `Mailbox/queryChanges` with `cannotCalculateChanges` while prioritising Email/queryChanges (https://lists.andrew.cmu.edu/pipermail/cyrus-devel/2018-July/004318.html [secondary]; fetch of the reply failed on a TLS error, so the content is from a search summary).
  - Which filters and sorts are supported is unknown. Rely on `canCalculateChanges` in each query response.
- **`canCalculateChanges`.** True if the server supports Foo/queryChanges for this filter/sort, but that "does not guarantee" the call will succeed (RFC 8620 §5.5 [primary]).
- **`/changes`** (RFC 8620 §5.2 [primary]):
  - `sinceState` is the `state` returned by Foo/get.
  - `cannotCalculateChanges` means "The client MUST invalidate its Foo cache".
  - `maxChanges`: the server "MAY choose to return fewer … but MUST NOT return more".
  - `hasMoreChanges`: call again with `newState`.
  - Servers "SHOULD be able to calculate changes from any state string" issued in the last 30 days.
  - Email/changes recommends returning newer changes first when generating intermediate states (RFC 8621 §4.3 [primary]).
- **`/queryChanges`** (RFC 8620 §5.6 [primary]):
  - Arguments: `sinceQueryState`, `maxChanges`, `upToId`, `calculateTotal`.
  - Response: `removed` ids and `added` {id, index}.
  - `tooManyChanges` error when changes exceed `maxChanges`.
  - `cannotCalculateChanges` error, "usually due to the client's state being too old"; the client "MUST invalidate its cache of the query results".
  - Email/queryChanges also takes the same `collapseThreads` value as the original query (RFC 8621 §4.5 [primary]).
- **State strings** (RFC 8620 §5.1 [primary]):
  - There is one state per data type per account: Email, Mailbox and Thread each have their own.
  - "If the data changes, this string MUST change"; servers SHOULD return the same string when nothing changed.
  - `queryState` is separate. It "only represents the ordered list of ids" and has meaning only against later responses to the same query (§5.5 [primary]).
  - The spec does not define any ordering of state strings. Inference: store them as opaque text and compare only for equality.
- **`/query` paging** (RFC 8620 §5.5 [primary]):
  - `position` is zero-based.
  - If `anchor` is given, "the 'position' argument is ignored"; `anchorOffset` may be negative; an unfound anchor gives `anchorNotFound`.
  - "The server MAY choose to enforce a maximum 'limit'". The response `limit` is "only returned if the server set a limit or used a different limit than that given in the request".
  - `total` "MUST be omitted if the 'calculateTotal' request argument is not true", and computing it "may be slow and expensive".
  - Other errors: `unsupportedSort`, `unsupportedFilter`.
- **`Email/query` specifics** (RFC 8621 §4.4.1–4.4.3 [primary]):
  - `after` matches `receivedAt` at or later than the given date-time; `before` matches strictly earlier.
  - `inMailbox` and `inMailboxOtherThan` filter by mailbox.
  - `receivedAt` sort "MUST be supported".
  - With `collapseThreads`, "A Thread will therefore only appear *once*".

## Q6: Email/get bodies and headers (RFC 8621 §4.1.4, §4.2 [primary], https://datatracker.ietf.org/doc/html/rfc8621)

- **`fetchTextBodyValues`, `fetchHTMLBodyValues`, `fetchAllBodyValues`.** These fill `bodyValues` for the `text/*` parts in `textBody`, `htmlBody` and `bodyStructure` respectively.
- **`maxBodyValueBytes`.** If > 0, each value "MUST be truncated if necessary so it does not exceed this number of octets in size"; the server "MUST ensure the truncation results in valid UTF-8" and it "does not occur mid-codepoint".
- **EmailBodyValue fields:**
  - `value`: after decoding Content-Transfer-Encoding
  - `isEncodingProblem`: "true if malformed sections were found while decoding"
  - `isTruncated`: "true if the 'value' has been truncated"
- **`textBody` vs `htmlBody` vs `bodyStructure`:**
  - `textBody` is "A list of 'text/plain', 'text/html', 'image/*', 'audio/*', and/or 'video/*' parts to display (sequentially)".
  - The reference algorithm adds HTML parts to `textBody` when there is no plaintext alternative ("Found HTML part only"), but the decomposition "is not mandated". An HTML-only message can therefore surface `text/html` parts in `textBody`.
  - `htmlBody` has "a preference for 'text/html' when alternative versions are available".
  - `bodyStructure` is the full MIME tree.
- **Attachment metadata.** `attachments` is "A list, traversing depth-first, of all parts in 'bodyStructure'" not shown as body (plus media parts not in both lists). The `hasAttachment` flag is separate.
  - Default `bodyProperties`: `partId, blobId, size, name, type, charset, disposition, cid, language, location`.
  - `size` is the octet count after transfer decoding.
  - Bytes come via `blobId` and `downloadUrl`.
- **Message-ID and related headers.** `messageId`, `inReplyTo` and `references` are `String[]|null`, identical to `header:Message-ID:asMessageIds` (and the In-Reply-To / References equivalents). Angle brackets and comments are removed; the value is null on a parse failure.
- **Other properties:**
  - `preview` is at most 256 characters.
  - `keywords` are returned lowercase.
  - `mailboxIds`: an Email "MUST belong to one or more Mailboxes at all times".

## Q7: Thread/get and Mailbox/get (RFC 8621 §2–3 [primary])

- **Thread/get.** `emailIds` are "sorted by the 'receivedAt' date of the Email, oldest first". Thread/changes is a standard /changes.
- **Mailbox properties:** `parentId` (null at top level), `role`, `sortOrder`, `totalEmails`, `unreadEmails`, `totalThreads`, `unreadThreads`, `myRights`.
  - `unreadEmails` excludes `$seen` and `$draft` messages.
  - A mailbox has at most one role, and roles are unique per account.
  - Role values are lowercased names from the IANA "IMAP Mailbox Name Attributes" registry, e.g. inbox, archive, drafts, sent, trash, junk, all, flagged. The full list was not confirmed in the fetched text.
- **Mailbox/changes.** It may return `updatedProperties` when only the count properties changed (§2.2), which lets a client refetch just the counts.

## Q8: Error shapes (RFC 8620 §3.6 [primary])

- **Request-level errors.** These are an HTTP error plus an RFC 7807 problem-details JSON body. Types:
  - `urn:ietf:params:jmap:error:unknownCapability`
  - `…:notJSON`
  - `…:notRequest`
  - `…:limit` (with a `limit` property)
- **Method-level errors.** These come back as an `["error", {type}, callId]` response, and other calls in the request still run. Types:
  - `serverUnavailable`, `serverFail`, `serverPartialFail`
  - `unknownMethod`, `invalidArguments`, `invalidResultReference`
  - `forbidden`, `accountNotFound`, `accountNotSupportedByMethod`, `accountReadOnly`
  - `requestTooLarge` (/get with too many ids, §5.1)
  - plus the /query and /changes errors listed under Q5.
- **401.** RFC 8620 requires authentication ("All HTTP requests MUST be authenticated", §1.7) but the fetched text does not specify a 401. Fastmail documents a 401 only for an expired OAuth access token (https://www.fastmail.com/dev/ [primary]). Inference: a bad bearer token returns HTTP 401 with no JMAP body.

## Implications for an M2-ready schema (inference, not decisions)

- Store one state per (accountId, type) for Email, Mailbox and Thread, captured from the `/get` responses taken during the M1 sync, as opaque text. These are the cursors for M2's `/changes`.
- Store the `queryState` together with the exact filter, sort and `collapseThreads` that produced it, plus `canCalculateChanges`. A bounded window (`after: X`) is a query, so Email/queryChanges may or may not be offered, and the schema must allow a fallback to Email/changes or a re-query.
- Plan for `cannotCalculateChanges` at any time, including past ~30 days: support a full-resync path that invalidates cached rows for that type.
- Email/changes is account-wide, not limited to the window. M2 must re-evaluate window membership after changes; storing `receivedAt` makes that cheap.
- Use a join table for mailbox membership (Email↔Mailbox, since `mailboxIds` holds many) and store keywords separately; both are mutable and change under /changes.
- Store `messageId`, `inReplyTo` and `references` as lists; don't assume one Message-ID.
- Body-value rows need `is_truncated`, `is_encoding_problem`, the source list (text/html/all), part `type`, and the `maxBodyValueBytes` used, so truncated bodies can be refetched later.
- Store attachment metadata per part: `partId`, `blobId`, `type`, `name`, `size`, `disposition`, `cid`. Content can be fetched later by `blobId`.
- Store session limits and `apiUrl` per session fetch, not as constants.

## Not documented / must read from live session

- All numeric limits: core caps, mail account caps, `emailQuerySortOptions`, and any server-capped query `limit`.
- Whether a read-only token sets `isReadOnly: true`, omits capabilities, or both; and whether writes return `accountReadOnly` or `forbidden`.
- Fastmail HTTP rate limits, 429 or `Retry-After` behaviour.
- Which Email/query filter/sort combinations get `canCalculateChanges: true`: read it from each query response.
- How long Fastmail retains change history beyond the spec's SHOULD of 30 days.
