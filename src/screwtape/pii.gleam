//// PII stripping: the shapes that can identify a person become placeholders
//// (design § 5.4). The module is self-contained — it imports only its own FFI
//// wrapper — so it can be reused or ported, and it knows nothing of mail or of
//// Screwtape's types.
////
//// Six rules, in this order: forged mask markers; URL userinfo; a URL's query
//// and fragment; runs of twenty or more letters and digits; IPv4 addresses;
//// and protected date/time shapes with runs of eight or more digits. Every
//// rule is a named pattern constant and a named replacement, so the rules and
//// their tests sit together. All matching is global, case-insensitive and
//// Unicode-aware.
////
//// Email addresses pass through unchanged, and a scheme-less URL gets rules 4
//// to 6 only. A URL keeps its host, port and path, losing just its userinfo
//// and, as `?[…]` or `#[…]`, its query or fragment.
////
//// Rule 6 needs masking, because a protected shape must survive the digit rule
//// untouched. One pass wraps every match in a pair of private-use markers
//// (U+E000 and U+E001): a protected shape is followed by an empty marker pair,
//// and a digit run is enclosed by a pair. The enclosed spans then collapse to
//// `[number]`, and the empty pairs are dropped. Markers already in the input
//// are removed first, so input cannot forge them.
////
//// A shape is protected only as a whole token (RV-016 F-2): no digit, and no
//// space, `.`, `/` or `-` followed by a digit, may touch either end. Otherwise
//// the digit rule could join it to its neighbours, so it is left to that rule:
//// `12.12.2026` and `12.12.2026 14:00` survive, while `12.12.2026 3456`,
//// `9 12.12.2026` and `12/12/2026 12345678` lose their digit runs.

/// The placeholder a run of twenty or more letters and digits becomes.
const token_replacement = "[token]"

/// The placeholder an IPv4 address becomes.
const ip_replacement = "[ip]"

/// The placeholder a long digit run becomes.
const number_replacement = "[number]"

/// What a stripped URL leaves in place of its query or fragment.
const ellipsis = "\u{2026}"

/// The mask markers: no meaning in the input, pure bookkeeping in between.
const mask_open = "\u{E000}"

const mask_close = "\u{E001}"

/// Rule 2: a userinfo, up to the last `@` of the authority.
const url_userinfo_pattern = "(https?://)[^/?#\\s<>\"']*@"

const url_userinfo_replacement = "\\1"

/// Rule 3: a URL's query and fragment, from the first `?` or `#` up to the
/// next whitespace, quote, `<` or `>`. The path and the port are kept, so the
/// result is `?[…]` or `#[…]`.
const url_query_pattern = "(https?://[^\\s<>\"'?#]*)([?#])[^\\s<>\"']*"

const url_query_replacement = "\\1\\2[" <> ellipsis <> "]"

/// Rule 4: a run of twenty or more letters and digits holding at least one of
/// each. The lookbehind lets a match attempt start only at a run's start, so
/// each run is scanned once and the scan stays linear.
const token_pattern =
  "(?<![A-Za-z0-9])(?=[A-Za-z]*[0-9])(?=[0-9]*[A-Za-z])[A-Za-z0-9]{20,}"

/// Rule 5: four dotted octets of one to three digits each.
const ipv4_pattern =
  "(?<![0-9.])(?:[0-9]{1,3}\\.){3}[0-9]{1,3}(?![0-9])(?!\\.[0-9])"

/// A day of the month, 1–31, leading zero allowed.
const day = "(?:0?[1-9]|[12][0-9]|3[01])"

/// A month, 1–12, leading zero allowed.
const month = "(?:0?[1-9]|1[0-2])"

const year4 = "[0-9]{4}"

/// A year of two or four digits.
const year24 = "(?:[0-9]{4}|[0-9]{2})"

const date_day_first = day <> "/" <> month <> "/" <> year24

const date_year_first = year4 <> "/" <> month <> "/" <> day

const date_dotted = day <> "\\." <> month <> "\\." <> year24

const date_iso = year4 <> "-[0-9]{2}-[0-9]{2}"

/// A clock time, seconds optional.
const time = "[0-9]{2}:[0-9]{2}(?::[0-9]{2})?"

/// An ISO datetime's time: a bounded fraction of a second is allowed, so a
/// long digit run cannot hide in it.
const iso_time = time <> "(?:\\.[0-9]{1,9})?"

/// A whole token: nothing that the digit rule would join may touch either end.
/// No digit, and no space, `.`, `/` or `-` followed by a digit. This holds for
/// every shape, slashed or not: the digit rule can join a slashed date's year
/// or a time's minutes to digits that follow a space.
const left = "(?<![0-9])(?<![0-9][ ./-])"

const right = "(?![0-9])(?![ ./-][0-9])"

const iso_datetime =
  left
  <> "(?:"
  <> date_iso
  <> "T"
  <> iso_time
  <> "(?:Z|[+-][0-9]{2}:?[0-9]{2})?)"
  <> right

const slash_date_with_time =
  left
  <> "(?:(?:"
  <> date_day_first
  <> "|"
  <> date_year_first
  <> ") "
  <> time
  <> ")"
  <> right

const dotted_date_with_time =
  left <> "(?:" <> date_dotted <> " " <> time <> ")" <> right

const iso_date_with_time =
  left <> "(?:" <> date_iso <> " " <> time <> ")" <> right

const iso_date_token = left <> "(?:" <> date_iso <> ")" <> right

const year_first_date_token = left <> "(?:" <> date_year_first <> ")" <> right

const day_first_date_token = left <> "(?:" <> date_day_first <> ")" <> right

const dotted_date_token = left <> "(?:" <> date_dotted <> ")" <> right

const time_token = left <> "(?:" <> time <> ")" <> right

/// Rule 6: every protected shape, longest first, so a date followed by a time
/// is taken whole before either half is. The whole alternation is one capture
/// group, which is what the mask replacement restores.
const protected_pattern =
  "("
  <> iso_datetime
  <> "|"
  <> slash_date_with_time
  <> "|"
  <> dotted_date_with_time
  <> "|"
  <> iso_date_with_time
  <> "|"
  <> iso_date_token
  <> "|"
  <> year_first_date_token
  <> "|"
  <> day_first_date_token
  <> "|"
  <> dotted_date_token
  <> "|"
  <> time_token
  <> ")"

/// Rule 6: eight or more digits, with single spaces, dashes or dots between
/// them. The scan is left to right and the run greedy, so a run is taken from
/// its first digit; only a digit may not precede it.
const number_pattern = "(?<![0-9])[0-9](?:[ .-]?[0-9]){7,}"

/// Shape and number in one pass, so the two are decided left to right against
/// the same text: group 1 is a protected shape, group 2 a digit run.
const mask_pattern = protected_pattern <> "|(" <> number_pattern <> ")"

const mask_replacement = "\\1" <> mask_open <> "\\2" <> mask_close

/// A marker-enclosed digit run, which is exactly what a number is now.
const masked_number_pattern =
  mask_open <> "[^" <> mask_open <> mask_close <> "]+" <> mask_close

/// The empty marker pair a protected shape carries.
const empty_mask_pattern = mask_open <> mask_close

/// Rule 1: a marker already in the input, which carries no meaning.
const forged_marker_pattern = "[" <> mask_open <> mask_close <> "]"

/// Replace everything that could identify a person with a placeholder.
pub fn strip(text: String) -> String {
  text
  |> replace(forged_marker_pattern, "")
  |> replace(url_userinfo_pattern, url_userinfo_replacement)
  |> replace(url_query_pattern, url_query_replacement)
  |> replace(token_pattern, token_replacement)
  |> replace(ipv4_pattern, ip_replacement)
  |> replace(mask_pattern, mask_replacement)
  |> replace(masked_number_pattern, number_replacement)
  |> replace(empty_mask_pattern, "")
}

@external(erlang, "screwtape_pii_ffi", "replace")
fn replace(text: String, pattern: String, replacement: String) -> String
