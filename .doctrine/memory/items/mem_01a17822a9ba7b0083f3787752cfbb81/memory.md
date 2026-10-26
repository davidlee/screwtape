**Pattern (SL-001 PHASE-07, `nix/module-eval.nix`):** evaluate the *flake output*
module in `home-manager.lib.homeManagerConfiguration { inherit pkgs; modules = [...]; }`
and assert on `config.systemd.user.{services,timers}.<name>` with `lib.assertMsg`
(one message per key), forced before a `runCommand` exists.

- HM `assertions` failures are `throw`s raised when `activationPackage.drvPath` is
  forced: `!(builtins.tryEval cfg.activationPackage.drvPath).success` is the negative case.
- Build-time rejects (e.g. a `writeTextFile` `checkPhase` that runs the program's own
  parser over the generated config): `pkgs.testers.testBuildFailure drv`, then grep
  `$out/testBuildFailure.log` for the reason. It only catches failure of *that* drv —
  a failing dependency fails the test itself, so expose the drv (an `internal`,
  `readOnly` option such as `services.<x>.configFile`).
- `writeShellApplication`/`writeTextFile` derivations expose `.text` at eval time
  (assert on wrapper argv without building); building them runs shellcheck.
- Prove options are wired: one override case setting every option off-default.
- Base test config values that a case overrides need `lib.mkDefault` (else
  "conflicting definition values").

**Traps:**
- `builtins.match` results lose string context: a store path extracted from text is
  absent from the build sandbox (re-add with `lib.addContextFrom`, or don't extract).
- `lib.hasInfix` builds a regex; a needle carrying store-path context errors
  ("is not allowed to refer to a store path") — wrap it in
  `builtins.unsafeDiscardStringContext`.
