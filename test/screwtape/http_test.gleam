//// Contract tests for the pure HTTP seam (design § 5.2): the status mapping
//// and the transport-failure mapping. Both are total functions, so these call
//// them directly; `jmap/client_test` still exercises them through the client.

import gleam/http/response.{type Response, Response}
import gleam/int
import gleam/list
import gleeunit
import gleeunit/should
import screwtape/error
import screwtape/http

pub fn main() -> Nil {
  gleeunit.main()
}

fn response(status: Int) -> Response(String) {
  Response(status: status, headers: [], body: "body")
}

pub fn status_2xx_test() {
  [200, 201, 204, 299]
  |> list.each(fn(status) {
    http.status(response(status))
    |> should.equal(Ok(response(status)))
  })
}

pub fn status_auth_test() {
  [401, 403]
  |> list.each(fn(status) {
    http.status(response(status))
    |> should.equal(Error(error.Auth(status)))
  })
}

pub fn status_rate_limited_test() {
  http.status(response(429))
  |> should.equal(Error(error.RateLimited))
}

pub fn status_other_test() {
  [199, 300, 302, 400, 404, 500, 503]
  |> list.each(fn(status) {
    http.status(response(status))
    |> should.equal(Error(error.Http("status_" <> int.to_string(status))))
  })
}

/// `TooLarge` names whichever bound the caller applied.
pub fn failure_table_test() {
  let cases = [
    #(http.Timeout, error.Http("timeout")),
    #(http.ConnectFailed, error.Http("connect_failed")),
    #(http.TlsFailed, error.Http("tls_failed")),
    #(http.BadUtf8, error.Http("bad_utf8")),
    #(http.TooLarge, error.LimitExceeded("a_bound")),
  ]

  cases
  |> list.each(fn(c) { http.failure(c.0, "a_bound") |> should.equal(c.1) })
}
