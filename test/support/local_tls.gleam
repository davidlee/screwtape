//// A loopback TLS test server and client (PHASE-01/EX-7, DEC-018).
////
//// `start` generates a CA and a server certificate for this run with
//// `public_key:pkix_test_data/1` (SANs: DNS `localhost` and IP `127.0.0.1`),
//// writes the CA chain as PEM into a fresh temporary directory, and listens
//// for TLS on `127.0.0.1` on a kernel-assigned port (bind port 0). It answers
//// a fixed minimal HTTP/1.1 `200` with body `ok` and `Connection: close`.
////
//// `start_for` is the same server with the certificate's DNS SAN chosen by the
//// test and no IP SAN, for hostname-verification negative controls.
////
//// URLs built here always use `localhost`, never `127.0.0.1`: `ssl` compares
//// the peer certificate against the host string in the URL (sheet A4).
////
//// This grows into PHASE-02's `local_jmap`.

import gleam/int

/// Opaque handle to the Erlang side of a running server.
pub type Handle

pub type Server {
  Server(handle: Handle, port: Int, ca_path: String)
}

pub type Response {
  Response(status: Int, body: String)
}

/// Start a listener and return its handle, port and generated CA PEM path.
pub fn start() -> Server {
  let handle = start_ffi()
  Server(handle, port_ffi(handle), ca_path_ffi(handle))
}

/// Start a listener whose certificate carries `dns_name` as its only SAN, so a
/// request for `https://localhost:<port>/` fails hostname verification.
pub fn start_for(dns_name: String) -> Server {
  let handle = start_for_ffi(dns_name)
  Server(handle, port_ffi(handle), ca_path_ffi(handle))
}

/// Close the listener and delete the temporary directory holding the CA PEM.
pub fn stop(server: Server) -> Nil {
  stop_ffi(server.handle)
}

/// The URL of `path` on this server, with `localhost` as the host.
pub fn url(server: Server, path: String) -> String {
  "https://localhost:" <> int.to_string(server.port) <> path
}

/// GET `url` with `verify_peer`, trusting only the CA certificates in
/// `ca_path` (`{cacertfile, CaPath}`).
pub fn get_verified(url: String, ca_path: String) -> Result(Response, String) {
  get_verified_ffi(url, ca_path)
  |> to_response
}

fn to_response(
  result: Result(#(Int, String), String),
) -> Result(Response, String) {
  case result {
    Ok(#(status, body)) -> Ok(Response(status: status, body: body))
    Error(reason) -> Error(reason)
  }
}

@external(erlang, "local_tls_ffi", "start")
fn start_ffi() -> Handle

@external(erlang, "local_tls_ffi", "start_for")
fn start_for_ffi(dns_name: String) -> Handle

@external(erlang, "local_tls_ffi", "stop")
fn stop_ffi(handle: Handle) -> Nil

@external(erlang, "local_tls_ffi", "port")
fn port_ffi(handle: Handle) -> Int

@external(erlang, "local_tls_ffi", "ca_path")
fn ca_path_ffi(handle: Handle) -> String

@external(erlang, "local_tls_ffi", "http_get_verified")
fn get_verified_ffi(
  url: String,
  ca_path: String,
) -> Result(#(Int, String), String)
