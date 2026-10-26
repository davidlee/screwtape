//// The JMAP client over an injected `Send` (design § 5.2, DEC-006).
////
//// PHASE-02 defines only the transport seam; `session`, `call` and the
//// byte `Budget` land with the client itself in PHASE-10.

import gleam/http/request.{type Request}
import gleam/http/response.{type Response}

/// Why a request produced no response. No variant carries the request or a
/// transport reason, either of which could hold the bearer token.
pub type HttpFailure {
  Timeout
  ConnectFailed
  TlsFailed
  BadUtf8
  TooLarge
}

/// The second argument caps the response body bytes this call may receive;
/// it must be positive (RV-001 F-29).
pub type Send =
  fn(Request(String), Int) -> Result(Response(String), HttpFailure)
