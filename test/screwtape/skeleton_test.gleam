//// Characterisation tests of the toolchain (PHASE-01/EX-3, EX-7): they must run
//// green inside the Nix build sandbox, so they use loopback only, bind port 0,
//// keep their files under a fresh temporary directory, and clean up.

import gleam/dynamic/decode
import gleam/string
import gleeunit
import gleeunit/should
import sqlight
import support/local_tls
import support/subprocess
import support/temp

pub fn main() -> Nil {
  gleeunit.main()
}

/// A sqlight row is the array of selected column values, so the first column
/// is decoded by index.
fn body_decoder() -> decode.Decoder(String) {
  use body <- decode.field(0, decode.string)
  decode.success(body)
}

/// VT-1: a sqlight round_trip on a temporary database *file*: create a table,
/// insert a row through a parameter, close the connection, reopen it, and read
/// the value back.
pub fn sqlight_round_trip_on_a_temp_file_test() {
  let dir = temp.dir("screwtape-sqlight")
  let path = dir <> "/screwtape.db"

  let assert Ok(connection) = sqlight.open(path)
  let assert Ok(Nil) =
    sqlight.exec(
      "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL)",
      on: connection,
    )
  let assert Ok(_) =
    sqlight.query(
      "INSERT INTO notes (body) VALUES (?)",
      on: connection,
      with: [sqlight.text("round trip")],
      expecting: decode.success(Nil),
    )
  let assert Ok(Nil) = sqlight.close(connection)

  // Reopen: the row must survive the close, so it really is on disk.
  let assert Ok(connection) = sqlight.open(path)
  let selected =
    sqlight.query(
      "SELECT body FROM notes WHERE id = ?",
      on: connection,
      with: [sqlight.int(1)],
      expecting: body_decoder(),
    )
  let assert Ok(Nil) = sqlight.close(connection)
  temp.remove_dir(dir)

  let assert Ok(rows) = selected
  rows |> should.equal(["round trip"])
}

/// VT-4: a loopback TLS server whose CA and server certificate come from
/// public_key:pkix_test_data/1 (SANs localhost and 127.0.0.1), reached by httpc
/// with verify_peer and cacertfile pointing at the generated CA. The URL host
/// is `localhost`, never `127.0.0.1` (sheet A4).
pub fn loopback_tls_pkix_test_data_cacertfile_test() {
  let server = local_tls.start()
  let fetched =
    local_tls.get_verified(local_tls.url(server, "/"), server.ca_path)
  local_tls.stop(server)

  let assert Ok(response) = fetched
  response.status |> should.equal(200)
  response.body |> should.equal("ok")
}

/// Negative control: the same request with a cacertfile holding a different,
/// freshly generated CA must fail. The failure is the TLS alert `unknown_ca`,
/// which proves certificate verification is actually on.
pub fn loopback_tls_foreign_cacertfile_fails_test() {
  let server = local_tls.start()
  let stranger = local_tls.start()
  let fetched =
    local_tls.get_verified(local_tls.url(server, "/"), stranger.ca_path)
  local_tls.stop(stranger)
  local_tls.stop(server)

  let reason = fetched |> should.be_error
  reason |> string.contains("unknown_ca") |> should.be_true
}

/// Hostname-verification negative control: the CA in `cacertfile` is the one
/// that signed the server certificate (so `unknown_ca` cannot be the reason),
/// but the certificate names `not-localhost.invalid` and carries no IP SAN
/// while the URL host is `localhost`. The request must fail on the hostname
/// check, which proves the peer certificate is compared against the URL host.
pub fn loopback_tls_hostname_mismatch_fails_test() {
  let server = local_tls.start_for("not-localhost.invalid")
  let fetched =
    local_tls.get_verified(local_tls.url(server, "/"), server.ca_path)
  local_tls.stop(server)

  let reason = fetched |> should.be_error
  // Observed: {failed_connect, ... {tls_alert, {bad_certificate,
  // "... {bad_cert, {hostname_check_failed, {requested, "localhost"},
  // {received, [{dNSName, "not-localhost.invalid"}]}}}"}}}
  reason |> string.contains("hostname_check_failed") |> should.be_true
  reason |> string.contains("not-localhost.invalid") |> should.be_true
}

/// VT-4 (subprocess half): the shipped artifact's `main`, spawned as a
/// process through the shipment's own entry point. It must exit cleanly and
/// say nothing on either stream (design § 5.2: nothing may print).
pub fn shipment_main_runs_as_a_subprocess_test() {
  let assert Ok(shipment) = subprocess.shipment_dir()
  let assert Ok(record) =
    subprocess.run(subprocess.entrypoint(shipment), ["run"])

  record.stdout |> should.equal(<<>>)
  record.stderr |> should.equal("")
  record.exit_code |> should.equal(0)
}
