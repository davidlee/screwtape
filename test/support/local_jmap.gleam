//// A scripted loopback TLS server for transport tests (PHASE-02/EX-2, DEC-018).
////
//// `start` takes a script of raw HTTP/1.1 replies and serves them in order,
//// one per request, over TLS from a CA generated per run. The certificate,
//// listener and connection loop are `local_tls_ffi:serve/2`'s, so there is one
//// bootstrap, not two; this module is only the script and the withholding
//// switch.
////
//// A `Reply` names its status, its own headers, its framing and its body.
//// `ContentLength` sends a `Content-Length` header and the body bytes;
//// `Chunked(chunk_size)` sends `Transfer-Encoding: chunked` and the body cut
//// into chunks of that size. Every reply sends `Connection: close`.
////
//// `withhold_end: True` is the reason this helper exists: the server sends the
//// headers and every body byte except the last piece, then waits for
//// `release`. For `ContentLength` the withheld piece is the body's last byte;
//// for `Chunked` it is the final chunk and the `0\r\n\r\n` terminator. No timer
//// is involved, so a test can prove that something returned *while the body was
//// still open* (`withholding`), which is what PHASE-02/VT-1 needs.
////
//// Requests that arrive after the script runs out are still counted (a JMAP
//// client that retried would show up as a second request) and answered with a
//// bare `500`.
////
//// URLs use `localhost`, never `127.0.0.1`: `ssl` compares the peer
//// certificate against the host string in the URL (sheet A4).

import gleam/int
import gleam/list

/// Opaque handle to the Erlang side of a running server.
pub type Handle

/// A running scripted server: its state process, its port and its CA PEM.
pub type Server {
  Server(handle: Handle, port: Int, ca_path: String)
}

/// How a reply's body is framed on the wire.
pub type Framing {
  ContentLength
  Chunked(chunk_size: Int)
}

/// One scripted response. `headers` are sent as given; the framing header is
/// added by the server. `body` is raw bytes, so a test can send invalid UTF-8.
pub type Reply {
  Reply(
    status: Int,
    headers: List(#(String, String)),
    framing: Framing,
    body: BitArray,
    withhold_end: Bool,
  )
}

/// Start a listener and hand it `script`, which is served one reply per
/// request.
pub fn start(script: List(Reply)) -> Server {
  let handle = start_ffi(list.map(script, wire_reply))
  Server(handle, port_ffi(handle), ca_path_ffi(handle))
}

/// Start a listener whose script is built from its own base URL
/// (`https://localhost:<port>`), so a session document can name the server's
/// own `apiUrl` (PHASE-10, D9).
pub fn start_with(script: fn(String) -> List(Reply)) -> Server {
  let server = start([])
  load_ffi(server.handle, list.map(script(url(server, "")), wire_reply))
  server
}

/// The URL of `path` on this server, with `localhost` as the host.
pub fn url(server: Server, path: String) -> String {
  "https://localhost:" <> int.to_string(server.port) <> path
}

/// How many requests the server has received, including any beyond the script.
pub fn request_count(server: Server) -> Int {
  request_count_ffi(server.handle)
}

/// True while a reply's end is being held back, i.e. from the moment the
/// server blocks until `release`.
pub fn withholding(server: Server) -> Bool {
  withholding_ffi(server.handle)
}

/// Send the withheld end (the last body byte, or the final chunk and the
/// terminator) and let the connection close.
pub fn release(server: Server) -> Nil {
  release_ffi(server.handle)
}

/// Close the listener, unblock anything withheld and delete the CA PEM.
pub fn stop(server: Server) -> Nil {
  stop_ffi(server.handle)
}

/// The Erlang side takes the reply as {Status, Headers, Framing, Body,
/// WithholdEnd}; framing stays a plain pair so no Gleam constructor has to be
/// understood across the boundary.
fn wire_reply(
  reply: Reply,
) -> #(Int, List(#(String, String)), #(String, Int), BitArray, Bool) {
  #(
    reply.status,
    reply.headers,
    wire_framing(reply.framing),
    reply.body,
    reply.withhold_end,
  )
}

fn wire_framing(framing: Framing) -> #(String, Int) {
  case framing {
    ContentLength -> #("content_length", 0)
    Chunked(chunk_size:) -> #("chunked", chunk_size)
  }
}

@external(erlang, "local_jmap_ffi", "start")
fn start_ffi(
  script: List(#(Int, List(#(String, String)), #(String, Int), BitArray, Bool)),
) -> Handle

@external(erlang, "local_jmap_ffi", "load")
fn load_ffi(
  handle: Handle,
  script: List(#(Int, List(#(String, String)), #(String, Int), BitArray, Bool)),
) -> Nil

@external(erlang, "local_jmap_ffi", "port")
fn port_ffi(handle: Handle) -> Int

@external(erlang, "local_jmap_ffi", "ca_path")
fn ca_path_ffi(handle: Handle) -> String

@external(erlang, "local_jmap_ffi", "request_count")
fn request_count_ffi(handle: Handle) -> Int

@external(erlang, "local_jmap_ffi", "withholding")
fn withholding_ffi(handle: Handle) -> Bool

@external(erlang, "local_jmap_ffi", "release")
fn release_ffi(handle: Handle) -> Nil

@external(erlang, "local_jmap_ffi", "stop")
fn stop_ffi(handle: Handle) -> Nil
