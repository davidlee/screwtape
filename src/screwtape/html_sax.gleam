//// The HTML parser boundary: htmgrrrl's SAX events, narrowed to the small
//// `Event` type `html_text` folds over (PHASE-03; design § 5.1, DEC-020).
////
//// This is the one governed module allowed to declare `@external` (invariant
//// I5, enforced by `just check-imports`). It also owns the parser's quirks:
//// htmerl reports element names in mixed case (`HTML`, `BR`, but also `title`),
//// so every element and attribute name is lowercased here once. The step
//// function handed to the FFI matches only what `html_text` needs and maps
//// everything else — comments, DTD, CDATA markers, processing instructions,
//// prefix mappings, and htmgrrrl's undeclared entity tuples — to `Other`.

import gleam/list
import gleam/string
import htmgrrrl

/// What `html_text` understands of a document, and nothing more.
pub type Event {
  Start(name: String, attributes: List(#(String, String)))
  End(name: String)
  Text(String)
  Other
}

@external(erlang, "screwtape_html_ffi", "sax")
fn ffi_sax(
  html: String,
  initial: state,
  step: fn(state, Int, htmgrrrl.SaxEvent) -> state,
) -> Result(state, Nil)

/// Feed `html` to the parser, presenting each event as `Event`.
pub fn sax(
  html: String,
  initial: state,
  step: fn(state, Int, Event) -> state,
) -> Result(state, Nil) {
  ffi_sax(html, initial, fn(state, line, event) {
    step(state, line, convert_event(event))
  })
}

fn convert_event(event: htmgrrrl.SaxEvent) -> Event {
  case event {
    htmgrrrl.StartElement(_, local_name, qualified_name, attributes) ->
      Start(
        element_name(local_name, qualified_name),
        list.map(attributes, attribute_pair),
      )
    htmgrrrl.EndElement(_, local_name, qualified_name) ->
      End(element_name(local_name, qualified_name))
    htmgrrrl.Characters(text) -> Text(text)
    htmgrrrl.IgnorableWhitespace(text) -> Text(text)
    _ -> Other
  }
}

fn element_name(
  local_name: String,
  qualified_name: #(String, String),
) -> String {
  let name = case local_name {
    "" -> qualified_name.1
    name -> name
  }
  string.lowercase(name)
}

fn attribute_pair(attribute: htmgrrrl.Attribute) -> #(String, String) {
  case attribute {
    htmgrrrl.Attribute(_, _, name, value) -> #(string.lowercase(name), value)
  }
}
