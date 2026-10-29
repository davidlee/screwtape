# screwtape's erlang-shipment, built offline from manifest.toml by nix-gleam.
# The flake's `checks.gleam-test` is this package with `doCheck` on.
{
  lib,
  beamPackages,
  buildGleamApplication,
  just,
  doCheck ? false,
}:
buildGleamApplication {
  src = lib.fileset.toSource {
    root = ./..;
    # `../test` only when `doCheck`: `gleam export erlang-shipment` compiles
    # every Erlang module it is given, so shipping the test helpers would put
    # subprocess_ffi, temp_ffi, local_tls_ffi and ffi_terms in the production
    # ebin.
    fileset = lib.fileset.unions (
      [
        ../gleam.toml
        ../manifest.toml
        ../src
      ]
      # The check also runs `just check-imports`, so it needs the justfile;
      # the docs test reads README.md.
      ++ lib.optionals doCheck [../test ../justfile ../README.md]
    );
  };

  # sqlight's esqlite NIF compiles through rebar3's pc plugin, which the
  # default rebar3 lacks (research L4, L9; ASM-001).
  rebar3Package = beamPackages.rebar3WithPlugins {plugins = [beamPackages.pc];};

  inherit doCheck;
  nativeCheckInputs = [just];
  # Runs after buildPhase, so build/erlang-shipment is the shipment under test.
  # `just check-imports` is the I5/I6 structural check (PHASE-03/EX-6).
  checkPhase = ''
    runHook preCheck
    export HOME="$TMPDIR"
    just check-imports
    gleam test
    runHook postCheck
  '';
}
