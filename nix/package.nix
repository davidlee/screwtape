# screwtape's erlang-shipment, built offline from manifest.toml by nix-gleam.
# The flake's `checks.gleam-test` is this package with `doCheck` on.
{
  lib,
  beamPackages,
  buildGleamApplication,
  doCheck ? false,
}:
buildGleamApplication {
  src = lib.fileset.toSource {
    root = ./..;
    fileset = lib.fileset.unions [
      ../gleam.toml
      ../manifest.toml
      ../src
      ../test
    ];
  };

  # sqlight's esqlite NIF compiles through rebar3's pc plugin, which the
  # default rebar3 lacks (research L4, L9; ASM-001).
  rebar3Package = beamPackages.rebar3WithPlugins {plugins = [beamPackages.pc];};

  inherit doCheck;
  # Runs after buildPhase, so build/erlang-shipment is the shipment under test.
  checkPhase = ''
    runHook preCheck
    export HOME="$TMPDIR"
    gleam test
    runHook postCheck
  '';
}
