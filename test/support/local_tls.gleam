//// A loopback TLS test server and client (PHASE-01/EX-7, DEC-018).
////
//// `start` generates a CA and a server certificate for this run with
//// `public_key:pkix_test_data/1` (SANs: DNS `localhost` and IP `127.0.0.1`),
//// writes the CA chain as PEM into a fresh temporary directory, and listens
//// for TLS on `127.0.0.1` on a kernel-assigned port (bind port 0). It answers
//// a fixed minimal HTTP/1.1 `200` with body `ok` and `Connection: close`.
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
  Server(handle: handle, port: port_ffi(handle), ca_path: ca_path_ffi(handle))
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

/// GET `url` with `verify_peer` and no CA source: the default trust store,
/// which must not contain a CA generated for this run.
pub fn get_without_cacertfile(url: String) -> Result(Response, String) {
  get_without_cacertfile_ffi(url)
  |> to_response
}

/// Create a fresh temporary directory, honouring `TMPDIR` (falling back to
/// `/tmp`), and return its path.
pub fn temp_dir(prefix: String) -> String {
  temp_dir_ffi(prefix)
}

/// Delete a temporary directory and everything in it.
pub fn remove_temp_dir(path: String) -> Nil {
  remove_temp_dir_ffi(path)
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

@external(erlang, "local_tls_ffi", "http_get_without_cacertfile")
fn get_without_cacertfile_ffi(url: String) -> Result(#(Int, String), String)

@external(erlang, "local_tls_ffi", "temp_dir")
fn temp_dir_ffi(prefix: String) -> String

@external(erlang, "local_tls_ffi", "remove_temp_dir")
fn remove_temp_dir_ffi(path: String) -> Nil
