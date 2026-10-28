//// The HTTP seam (design § 5.2): the transport `Send`, its failure type, and
//// the two pure mappings — a response's status into an `Error`, and a
//// transport failure into an `Error`.
////
//// Nothing here performs I/O: `Send` is a type a caller's adapter satisfies,
//// and both mappings are total functions over their arguments. The status and
//// failure mappings live here once, so `screwtape/jmap/client` never restates
//// them.

import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import screwtape/error.{type Error}

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

/// D2: 2xx is the call's; 401/403 are `Auth`; 429 is `RateLimited`; any other
/// non-2xx is its status as `Http`. (The JMAP problem document is the caller's
/// branch: it turns an `Http(_)` answer into a `JmapRequest` when it decodes.)
pub fn status(response: Response(String)) -> Result(Response(String), Error) {
  let code = response.status
  case code >= 200 && code < 300 {
    True -> Ok(response)
    False ->
      case code {
        401 | 403 -> Error(error.Auth(code))
        429 -> Error(error.RateLimited)
        _ -> Error(error.Http("status_" <> int.to_string(code)))
      }
  }
}

/// A transport failure is a fixed reason; `TooLarge` is the budget's ceiling,
/// not the transport's, so it names the bound the caller applied.
pub fn failure(failure: HttpFailure, too_large: String) -> Error {
  case failure {
    Timeout -> error.Http("timeout")
    ConnectFailed -> error.Http("connect_failed")
    TlsFailed -> error.Http("tls_failed")
    BadUtf8 -> error.Http("bad_utf8")
    TooLarge -> error.LimitExceeded(too_large)
  }
}
