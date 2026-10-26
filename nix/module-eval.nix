# PHASE-07 contract check (EX-3, VT-1, VT-2; design § 9 I1/I7/I9 eval halves).
#
# Evaluates the *flake output* `self.homeManagerModules.default` — never the
# file path — in a minimal Home Manager configuration with no VM, and asserts:
#
#   * every EX-1 hardening key of screwtape.service, verbatim (Type=oneshot,
#     StateDirectoryMode, LoadCredentialEncrypted, ProtectHome, LimitCORE,
#     ERL_CRASH_DUMP_SECONDS), the timeout and MemoryMax bounds;
#   * screwtape.timer: OnCalendar, Persistent, Install.WantedBy;
#   * that the timer/service knobs are options, not literals (a second
#     configuration overrides them);
#   * the wrapper only adds `--config` (DEC-017, I9) and home.packages carries
#     the wrapper and screwtape-provision but not the raw package;
#   * the module source contains no `/home/` (NF-006);
#   * VT-2: a customised xdg.stateHome fails evaluation (the module's own
#     assertion, RV-001 F-31), caught with `tryEval`.
#
# The build-time half then feeds the module's own generated JSON config to the
# packaged binary: the real decoder must accept it. Exit 1 (the store does not
# exist) is the pass; exit 2 means the config was rejected.
{
  self,
  pkgs,
  home-manager,
}:
let
  lib = pkgs.lib;

  # One Home Manager configuration per case: the module under test plus the
  # minimal user it needs.
  hm = extra:
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        self.homeManagerModules.default
        {
          home.username = "operator";
          home.homeDirectory = "/home/operator";
          home.stateVersion = "25.05";
          services.screwtape = {
            enable = true;
            opRef = "op://Vault/Item/credential";
          };
        }
        extra
      ];
    };

  ok = hm {};

  # VT-2: the module asserts xdg.stateHome is the default. `tryEval` catches
  # throw/assert, which is what a Home Manager assertion failure is, so this is
  # true exactly when the customised case was rejected.
  neg = hm { xdg.stateHome = "/tmp/screwtape-state"; };
  negRejected = !(builtins.tryEval neg.activationPackage.drvPath).success;

  # Render a unit option the way systemd does: list-ish values joined with
  # spaces, booleans as true/false, integers as digits. Lets the contract accept
  # either spelling of `RestrictAddressFamilies` (one string or a list of
  # families), `LoadCredentialEncrypted`, `SystemCallFilter`, `LimitCORE` and
  # the rest.
  render = v:
    if lib.isList v
    then lib.concatMapStringsSep " " render v
    else if lib.isBool v
    then (if v then "true" else "false")
    else toString v;

  # A missing unit option reads as null, so a check fails with its own message
  # naming the key rather than an "attribute missing" error.
  field = set: name: set.${name} or null;
  eq = set: name: expected: render (field set name) == expected;

  asList = v: if v == null then [] else lib.toList v;

  # `Environment` is one string or a list of assignments (HM's unitOption).
  # Either spelling contains ERL_CRASH_DUMP_SECONDS=0 when some entry is that
  # exact assignment.
  envHas = expected: env:
    if lib.isAttrs env then
      let
        parts = lib.splitString "=" expected;
        name = lib.head parts;
        value = lib.concatStringsSep "=" (lib.tail parts);
      in
        builtins.hasAttr name env && render env.${name} == value
    else
      lib.any (v: lib.elem expected (lib.splitString " " (render v))) (asList env);

  svc = (ok.config.systemd.user.services.screwtape or {}).Service or {};
  tim = (ok.config.systemd.user.timers.screwtape or {}).Timer or {};
  ins = (ok.config.systemd.user.timers.screwtape or {}).Install or {};

  # The same knobs, set to non-default values: proves they are options and that
  # the units take their values from them.
  over = hm {
    services.screwtape = {
      onCalendar = "hourly";
      timeoutStartSec = "1min";
      memoryMax = "512M";
    };
  };
  overSvc = (over.config.systemd.user.services.screwtape or {}).Service or {};
  overTim = (over.config.systemd.user.timers.screwtape or {}).Timer or {};

  # D4: the wrapper is the package called `screwtape` that carries `text`
  # (writeShellApplication = writeTextFile); the raw package has no text.
  packages = ok.config.home.packages;
  wrapper = lib.findFirst (p: (p.name or "") == "screwtape" && p ? text) null packages;
  wrapperText = if wrapper == null then "" else wrapper.text;
  provision = lib.findFirst (p: (p.name or "") == "screwtape-provision") null packages;

  execLines = lib.filter (l: builtins.match " *exec .*" l != null) (lib.splitString "\n" wrapperText);
  execLine = if lib.length execLines == 1 then lib.head execLines else "";

  # I9: the wrapper only adds --config; every other argument comes from the
  # caller. `exec <package>/bin/screwtape --config <configFile> "$@"`.
  execMatch = builtins.match "exec ([^ ]+)/bin/screwtape --config ([^ ]+) \"\\$@\"" execLine;
  wrapperPackage = if execMatch == null then "" else lib.elemAt execMatch 0;
  configPath = if execMatch == null then "" else lib.elemAt execMatch 1;

  screwtapePackage = ok.config.services.screwtape.package;
  wrapperPath = if wrapper == null then "" else toString wrapper;
  execStart = render (field svc "ExecStart");
  wantedBy = asList (field ins "WantedBy");

  checks = [
    # ---- screwtape.service: the EX-1 hardening keys, verbatim --------------
    (lib.assertMsg (eq svc "Type" "oneshot")
      "systemd.user.services.screwtape.Service.Type: want oneshot")
    (lib.assertMsg (eq svc "StateDirectory" "screwtape")
      "systemd.user.services.screwtape.Service.StateDirectory: want screwtape")
    (lib.assertMsg (eq svc "StateDirectoryMode" "0700")
      "systemd.user.services.screwtape.Service.StateDirectoryMode: want 0700")
    (lib.assertMsg (eq svc "LoadCredentialEncrypted" "fastmail:%E/credstore.encrypted/screwtape.fastmail")
      "systemd.user.services.screwtape.Service.LoadCredentialEncrypted: want fastmail:%E/credstore.encrypted/screwtape.fastmail")
    (lib.assertMsg (eq svc "NoNewPrivileges" "true")
      "systemd.user.services.screwtape.Service.NoNewPrivileges: want true")
    (lib.assertMsg (eq svc "PrivateTmp" "true")
      "systemd.user.services.screwtape.Service.PrivateTmp: want true")
    (lib.assertMsg (eq svc "ProtectSystem" "strict")
      "systemd.user.services.screwtape.Service.ProtectSystem: want strict")
    (lib.assertMsg (eq svc "ProtectHome" "tmpfs")
      "systemd.user.services.screwtape.Service.ProtectHome: want tmpfs")
    (lib.assertMsg (eq svc "RestrictAddressFamilies" "AF_UNIX AF_INET AF_INET6")
      "systemd.user.services.screwtape.Service.RestrictAddressFamilies: want AF_UNIX AF_INET AF_INET6")
    (lib.assertMsg (eq svc "SystemCallFilter" "@system-service")
      "systemd.user.services.screwtape.Service.SystemCallFilter: want @system-service")
    (lib.assertMsg (eq svc "UMask" "0077")
      "systemd.user.services.screwtape.Service.UMask: want 0077")
    (lib.assertMsg (eq svc "LimitCORE" "0")
      "systemd.user.services.screwtape.Service.LimitCORE: want 0 (no core dump)")
    (lib.assertMsg (envHas "ERL_CRASH_DUMP_SECONDS=0" (field svc "Environment"))
      "systemd.user.services.screwtape.Service.Environment: must contain ERL_CRASH_DUMP_SECONDS=0")
    (lib.assertMsg (eq svc "TimeoutStartSec" "5min")
      "systemd.user.services.screwtape.Service.TimeoutStartSec: want 5min (default)")
    (lib.assertMsg (eq svc "MemoryMax" "1G")
      "systemd.user.services.screwtape.Service.MemoryMax: want 1G (default)")

    # ---- ExecStart: one argv source for wrapper and unit (I9) --------------
    (lib.assertMsg (lib.hasSuffix "/bin/screwtape sync" execStart)
      "systemd.user.services.screwtape.Service.ExecStart: want it to end with /bin/screwtape sync")
    (lib.assertMsg (wrapper != null && lib.hasPrefix "${wrapperPath}/bin/screwtape" execStart)
      "systemd.user.services.screwtape.Service.ExecStart: want it to start with the wrapper's store path")

    # ---- screwtape.timer ---------------------------------------------------
    (lib.assertMsg (eq tim "OnCalendar" "*:0/15")
      "systemd.user.timers.screwtape.Timer.OnCalendar: want *:0/15 (default)")
    (lib.assertMsg (eq tim "Persistent" "true")
      "systemd.user.timers.screwtape.Timer.Persistent: want true")
    (lib.assertMsg (lib.any (w: render w == "timers.target") wantedBy)
      "systemd.user.timers.screwtape.Install.WantedBy: want timers.target")

    # ---- the knobs are options, not literals ------------------------------
    (lib.assertMsg (eq overTim "OnCalendar" "hourly")
      "systemd.user.timers.screwtape.Timer.OnCalendar: services.screwtape.onCalendar must reach the timer")
    (lib.assertMsg (eq overSvc "TimeoutStartSec" "1min")
      "systemd.user.services.screwtape.Service.TimeoutStartSec: services.screwtape.timeoutStartSec must reach the unit")
    (lib.assertMsg (eq overSvc "MemoryMax" "512M")
      "systemd.user.services.screwtape.Service.MemoryMax: services.screwtape.memoryMax must reach the unit")

    # ---- the wrapper: only --config, and the packages home.packages holds --
    (lib.assertMsg (lib.length execLines == 1)
      "home.packages screwtape wrapper: want exactly one exec line (the wrapper only adds --config)")
    (lib.assertMsg (execMatch != null)
      "home.packages screwtape wrapper: want `exec <package>/bin/screwtape --config <configFile> \"$@\"` and no other argument (I9)")
    (lib.assertMsg (wrapperPackage == toString screwtapePackage)
      "home.packages screwtape wrapper: want --config's sibling to be services.screwtape.package")
    (lib.assertMsg (lib.hasPrefix "/nix/store/" configPath && lib.hasSuffix "screwtape.json" configPath)
      "home.packages screwtape wrapper: --config must be a /nix/store path ending in screwtape.json")
    (lib.assertMsg (provision != null)
      "home.packages: want a screwtape-provision package")
    (lib.assertMsg (!(lib.any (p: (p.outPath or "") == toString screwtapePackage) packages))
      "home.packages: must not carry the raw services.screwtape.package itself")

    # ---- the config's state directory and NF-006 ---------------------------
    (lib.assertMsg (ok.config.xdg.stateHome == "/home/operator/.local/state")
      "xdg.stateHome: want the default /home/operator/.local/state (EX-2, RV-001 F-31)")
    (lib.assertMsg (!(lib.hasInfix "/home/" (builtins.readFile ./module.nix)))
      "nix/module.nix: must contain no /home/ literal (NF-006)")
    (lib.assertMsg negRejected
      "xdg.stateHome: a customised (non-default) xdg.stateHome must fail evaluation (VT-2)")
  ];
in
  # Force every check before the derivation exists; each failing check throws
  # with its own message.
  assert lib.all (x: x) checks;
  # The positive case must evaluate all the way to an activation package.
  assert builtins.isString ok.activationPackage.drvPath;
  pkgs.runCommand "screwtape-module-eval" {} ''
    set -eu
    export HOME="$TMPDIR"
    # builtins.match drops string context; the wrapper's closure holds the config.
    cfg=${lib.addContextFrom wrapper configPath}

    # D3: the generated config, key by key, as src/screwtape/config.gleam
    # decodes it. ca_file is JSON null (the system store is trusted).
    ${pkgs.jq}/bin/jq -e '
      .session_url == "https://api.fastmail.com/jmap/session" and
      .credential_name == "fastmail" and
      .store_path == "/home/operator/.local/state/screwtape/mail.sqlite3" and
      .window == {"mailboxes": ["inbox"], "max_age_days": 30, "max_messages": 2000} and
      .max_body_bytes == 262144 and
      .max_pages == 20 and
      .max_total_bytes == 268435456 and
      .request_timeout_ms == 30000 and
      .ca_file == null
    ' "$cfg" > /dev/null

    # The packaged binary must accept the module's config: 1 is a missing
    # store, 2 is a rejected config.
    status=0
    ${screwtapePackage}/bin/screwtape --config "$cfg" mailboxes || status=$?
    if [ "$status" -ne 1 ]; then
      echo "screwtape --config <module config> mailboxes: exit $status (want 1; 2 means the config was rejected)" >&2
      exit 1
    fi

    # Building it runs writeShellApplication's shellcheck over the script.
    test -x ${provision}/bin/screwtape-provision

    touch $out
  ''
