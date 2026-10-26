//// JMAP documents the tests hand to a decoder or serve from a scripted
//// `local_jmap` (PHASE-10, EX-2).
////
//// `session` is generated rather than read: it has to name the URL of the
//// server a test just started. The rest are fixtures under
//// `test/fixtures/jmap/`, read through `screwtape/file`; a missing fixture
//// crashes the test that asked for it.

import screwtape/file

/// A session document naming `api_url`, in the shape `decode.session` accepts.
pub fn session(api_url: String) -> String {
  "{\"apiUrl\":\""
  <> api_url
  <> "\""
  <> ",\"username\":\"operator@example.test\""
  <> ",\"primaryAccounts\":{\"urn:ietf:params:jmap:mail\":\"acct-1\"}"
  <> ",\"accounts\":{\"acct-1\":{\"name\":\"operator@example.test\","
  <> "\"isReadOnly\":false}}"
  <> ",\"capabilities\":{\"urn:ietf:params:jmap:core\":"
  <> "{\"maxObjectsInGet\":1000,\"maxCallsInRequest\":32}"
  <> ",\"urn:ietf:params:jmap:mail\":{}}}"
}

/// The UTF-8 text of `test/fixtures/jmap/<name>`.
pub fn text(name: String) -> String {
  let assert Ok(text) = file.read_text("test/fixtures/jmap/" <> name)
  text
}
