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
}: let
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
            opRef = lib.mkDefault "op://Vault/Item/credential";
          };
        }
        extra
      ];
    };

  ok = hm {};

  # VT-2: the module asserts xdg.stateHome (and xdg.configHome) are their
  # defaults. `tryEval` catches throw/assert, which is what a Home Manager
  # assertion failure is, so `rejects` is true exactly when evaluation failed.
  rejects = extra: !(builtins.tryEval (hm extra).activationPackage.drvPath).success;
  negRejected = rejects {xdg.stateHome = "/home/operator/.xdg/state";};
  # The unit's %E resolves from the user manager's default too.
  negConfigHomeRejected = rejects {xdg.configHome = "/home/operator/.xdg/config";};

  # Render a unit option the way systemd does: list-ish values joined with
  # spaces, booleans as true/false, integers as digits. Lets the contract accept
  # either spelling of `RestrictAddressFamilies` (one string or a list of
  # families), `LoadCredentialEncrypted`, `SystemCallFilter`, `LimitCORE` and
  # the rest.
  render = v:
    if lib.isList v
    then lib.concatMapStringsSep " " render v
    else if lib.isBool v
    then
      (
        if v
        then "true"
        else "false"
      )
    else toString v;

  # A missing unit option reads as null, so a check fails with its own message
  # naming the key rather than an "attribute missing" error.
  field = set: name: set.${name} or null;
  eq = set: name: expected: render (field set name) == expected;

  asList = v:
    if v == null
    then []
    else lib.toList v;

  # `Environment` is one string or a list of assignments (HM's unitOption).
  # Either spelling contains ERL_CRASH_DUMP_SECONDS=0 when some entry is that
  # exact assignment.
  envHas = expected: env:
    if lib.isAttrs env
    then let
      parts = lib.splitString "=" expected;
      name = lib.head parts;
      value = lib.concatStringsSep "=" (lib.tail parts);
    in
      builtins.hasAttr name env && render env.${name} == value
    else lib.any (v: lib.elem expected (lib.splitString " " (render v))) (asList env);

  svc = (ok.config.systemd.user.services.screwtape or {}).Service or {};
  tim = (ok.config.systemd.user.timers.screwtape or {}).Timer or {};
  ins = (ok.config.systemd.user.timers.screwtape or {}).Install or {};

  # The same knobs, set to non-default values: proves they are options and that
  # the units take their values from them.
  # A stand-in package with its own store path, so the wrapper must take
  # services.screwtape.package rather than the flake's default.
  otherPackage = pkgs.symlinkJoin {
    name = "screwtape-other";
    paths = [self.packages.${pkgs.stdenv.hostPlatform.system}.default];
  };
  over = hm {
    services.screwtape = {
      package = otherPackage;
      opRef = "op://Other/Item/token";
      sessionUrl = "https://jmap.example/session";
      window = {
        mailboxes = ["inbox" "Archive"];
        maxAgeDays = null;
        maxMessages = 10;
        retainMessages = 20;
      };
      maxBodyBytes = 1000;
      maxPages = 3;
      maxTotalBytes = 50000;
      requestTimeoutMs = 4000;
      caFile = "/etc/ssl/other.pem";
      onCalendar = "hourly";
      timeoutStartSec = "1min";
      memoryMax = "512M";
    };
  };
  # The text of a configuration's home package of that name ("" if absent).
  packageText = cfg: name: (lib.findFirst (p: (p.name or "") == name) {text = "";} cfg.config.home.packages).text;
  overText = packageText over;

  # The Jev key ingress (DEC-038): same module, `jev` set.
  withJev = hm {
    services.screwtape.jev = {
      baseUrl = "http://127.0.0.1:4000";
      model = "typesafe/jev-1.14.0";
    };
  };
  jevWrapperText = packageText withJev "screwtape";
  jevProvisionText = packageText withJev "screwtape-provision";
  homePackage = cfg: name: lib.findFirst (p: (p.name or "") == name) null cfg.config.home.packages;
  jevProvision = homePackage withJev "screwtape-provision";
  jevWrapper = homePackage withJev "screwtape";
  linesOf = text: lib.splitString "\n" (builtins.unsafeDiscardStringContext text);
  runLines = text: lib.filter (l: lib.hasInfix "systemd-run" l && builtins.match " *exec .*" l != null) (linesOf text);
  # What the module's inputs must assemble to: the one transient-unit exec line.
  expectedJevExec = builtins.unsafeDiscardStringContext (lib.concatStringsSep " " [
    "exec ${pkgs.systemd}/bin/systemd-run --user --pipe --quiet --wait --collect"
    "-p 'LoadCredentialEncrypted=jev:${withJev.config.xdg.configHome}/credstore.encrypted/screwtape.jev'"
    "-p LimitCORE=0 -E ERL_CRASH_DUMP_SECONDS=0"
    "${withJev.config.services.screwtape.package}/bin/screwtape --config ${withJev.config.services.screwtape.configFile} \"$@\""
  ]);
  # classify, but not exactly `classify --state`, takes the credential-loading branch.
  jevBranchTest = ''if [ "''${1-}" = classify ] && ! { [ "$#" -eq 2 ] && [ "$2" = --state ]; }; then'';
  fallthroughExec = builtins.unsafeDiscardStringContext "exec ${withJev.config.services.screwtape.package}/bin/screwtape --config ${withJev.config.services.screwtape.configFile} \"$@\"";
  jevSvc = (withJev.config.systemd.user.services.screwtape or {}).Service or {};

  # The generated config goes through the program's own parser at build time:
  # one the parser rejects must fail to build, and say why.
  badConfig = window: extra:
    pkgs.testers.testBuildFailure
    (hm {
      services.screwtape = {inherit window;} // extra;
    }).config.services.screwtape.configFile;
  noWindowBound = badConfig {
    maxAgeDays = null;
    maxMessages = null;
  } {};
  plainHttp = badConfig {} {sessionUrl = "http://jmap.example/session";};
  overSvc = (over.config.systemd.user.services.screwtape or {}).Service or {};
  overTim = (over.config.systemd.user.timers.screwtape or {}).Timer or {};

  # D4: the wrapper is the package called `screwtape` that carries `text`
  # (writeShellApplication = writeTextFile); the raw package has no text.
  packages = ok.config.home.packages;
  wrapper = lib.findFirst (p: (p.name or "") == "screwtape" && p ? text) null packages;
  wrapperText =
    if wrapper == null
    then ""
    else wrapper.text;
  provision = lib.findFirst (p: (p.name or "") == "screwtape-provision") null packages;
  provisionText =
    if provision == null
    then ""
    else provision.text;
  configFile = ok.config.services.screwtape.configFile;

  execLines = lib.filter (l: builtins.match " *exec .*" l != null) (lib.splitString "\n" wrapperText);
  execLine =
    if lib.length execLines == 1
    then lib.head execLines
    else "";

  # I9: the wrapper only adds --config; every other argument comes from the
  # caller. `exec <package>/bin/screwtape --config <configFile> "$@"`.
  execMatch = builtins.match "exec ([^ ]+)/bin/screwtape --config ([^ ]+) \"\\$@\"" execLine;
  wrapperPackage =
    if execMatch == null
    then ""
    else lib.elemAt execMatch 0;
  configPath =
    if execMatch == null
    then ""
    else lib.elemAt execMatch 1;

  screwtapePackage = ok.config.services.screwtape.package;
  wrapperPath =
    if wrapper == null
    then ""
    else toString wrapper;
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
    (lib.assertMsg (configPath == toString configFile)
      "home.packages screwtape wrapper: --config must be services.screwtape.configFile")
    (lib.assertMsg (provision != null)
      "home.packages: want a screwtape-provision package")
    (lib.assertMsg (!(lib.any (p: (p.outPath or "") == toString screwtapePackage) packages))
      "home.packages: must not carry the raw services.screwtape.package itself")

    # ---- the config's state directory and NF-006 ---------------------------
    (lib.assertMsg (ok.config.xdg.stateHome == "/home/operator/.local/state")
      "xdg.stateHome: want the default /home/operator/.local/state (EX-2, RV-001 F-31)")
    (lib.assertMsg (ok.config.services.screwtape.storeDir == "/home/operator/.local/state/screwtape")
      "services.screwtape.storeDir: want the unit's StateDirectory, /home/operator/.local/state/screwtape (DEC-031)")
    (lib.assertMsg (!(lib.hasInfix "/home/" (builtins.readFile ./module.nix)))
      "nix/module.nix: must contain no /home/ literal (NF-006)")
    (lib.assertMsg negRejected
      "xdg.stateHome: a customised (non-default) xdg.stateHome must fail evaluation (VT-2)")
    (lib.assertMsg negConfigHomeRejected
      "xdg.configHome: a customised xdg.configHome must fail evaluation (%E must match the credential's path)")

    # ---- screwtape-provision: the credential the unit loads ----------------
    (lib.assertMsg (lib.hasInfix "--name=fastmail " provisionText)
      "screwtape-provision: systemd-creds --name must be the unit's credential id, fastmail")
    (lib.assertMsg (lib.hasInfix "/home/operator/.config/credstore.encrypted/screwtape.fastmail" provisionText)
      "screwtape-provision: must write %E/credstore.encrypted/screwtape.fastmail, %E being xdg.configHome")

    # ---- the Jev ingress: wrapper, crash-dump parity, provision (EX-1..3) ----
    (lib.assertMsg (wrapper != null && !(lib.hasInfix "systemd-run" wrapperText))
      "wrapper (jev unset): must not mention systemd-run; it stays the single --config exec")
    (lib.assertMsg (lib.length (runLines jevWrapperText) == 1 && lib.head (runLines jevWrapperText) == "  ${expectedJevExec}")
      "wrapper (jev set): want exactly one systemd-run exec line: ${expectedJevExec}")
    (lib.assertMsg (lib.elem fallthroughExec (map (lib.removePrefix "  ") (linesOf jevWrapperText)))
      "wrapper (jev set): want the plain `exec <package>/bin/screwtape --config <configFile> \"$@\"` fallthrough line")
    (lib.assertMsg (lib.elem jevBranchTest (linesOf jevWrapperText))
      "wrapper (jev set): want the branch test exactly: ${jevBranchTest}")
    (lib.assertMsg (eq jevSvc "LimitCORE" "0"
      && envHas "ERL_CRASH_DUMP_SECONDS=0" (field jevSvc "Environment")
      && lib.hasInfix "-p LimitCORE=0 -E ERL_CRASH_DUMP_SECONDS=0 " (builtins.unsafeDiscardStringContext jevWrapperText))
    "crash-dump parity: the wrapper's LimitCORE / ERL_CRASH_DUMP_SECONDS must equal the service's")
    (lib.assertMsg (lib.hasInfix "--name=jev " jevProvisionText)
      "screwtape-provision (jev set): systemd-creds --name must be the wrapper's credential id, jev")
    (lib.assertMsg (lib.hasInfix "/home/operator/.config/credstore.encrypted/screwtape.jev" jevProvisionText)
      "screwtape-provision (jev set): must write credstore.encrypted/screwtape.jev under xdg.configHome")
    (lib.assertMsg (lib.hasInfix "--from-file" jevProvisionText)
      "screwtape-provision (jev set): must accept --from-file")
    (lib.assertMsg (lib.hasInfix "--name=fastmail " provisionText && !(lib.hasInfix "screwtape.jev" provisionText))
      "screwtape-provision (jev unset): fastmail only; jev is not accepted")

    # ---- every option reaches the unit, the wrapper or the provision script --
    (lib.assertMsg (lib.hasInfix (builtins.unsafeDiscardStringContext "exec ${otherPackage}/bin/screwtape --config ") (overText "screwtape"))
      "home.packages screwtape wrapper: must exec services.screwtape.package")
    (lib.assertMsg (lib.hasInfix "op://Other/Item/token" (overText "screwtape-provision"))
      "screwtape-provision: must read services.screwtape.opRef")
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
      cd "$TMPDIR"
      cfg=${configFile}

      # D3: the generated config, key by key, as src/screwtape/config.gleam
      # decodes it. ca_file is JSON null (the system store is trusted).
      ${pkgs.jq}/bin/jq -e '
        .session_url == "https://api.fastmail.com/jmap/session" and
        .credential_name == "fastmail" and
        .store_path == "/home/operator/.local/state/screwtape/mail.sqlite3" and
        .window == {"mailboxes": ["inbox"], "max_age_days": 30, "max_messages": 2000, "retain_messages": null} and
        .max_body_bytes == 262144 and
        .max_pages == 20 and
        .max_total_bytes == 268435456 and
        .request_timeout_ms == 30000 and
        .ca_file == null
      ' "$cfg" > /dev/null

      # Every config option, set away from its default, reaches the config.
      ${pkgs.jq}/bin/jq -e '
        .session_url == "https://jmap.example/session" and
        .window == {"mailboxes": ["inbox", "Archive"], "max_age_days": null, "max_messages": 10, "retain_messages": 20} and
        .max_body_bytes == 1000 and
        .max_pages == 3 and
        .max_total_bytes == 50000 and
        .request_timeout_ms == 4000 and
        .ca_file == "/etc/ssl/other.pem"
      ' ${over.config.services.screwtape.configFile} > /dev/null

      # Configs the parser rejects fail to build, for the parser's reason.
      grep -q no_window_bound ${noWindowBound}/testBuildFailure.log
      grep -q '"error":"config"' ${plainHttp}/testBuildFailure.log

      # The program accepts the jev block, and ok config has none (jev = null).
      ${pkgs.jq}/bin/jq -e '.jev == null' "$cfg" > /dev/null
      ${pkgs.jq}/bin/jq -e '
        .jev == {"base_url": "http://127.0.0.1:4000", "credential_name": "jev", "model": "typesafe/jev-1.14.0"}
      ' ${withJev.config.services.screwtape.configFile} > /dev/null

      # Building it runs writeShellApplication's shellcheck over the scripts
      # and wrappers, jev set or not.
      test -x ${provision}/bin/screwtape-provision
      test -x ${jevProvision}/bin/screwtape-provision
      test -x ${jevWrapper}/bin/screwtape

      # Bad arguments: usage, exit 2, nothing written; never reaching op or
      # systemd-creds.
      expect_usage() {
        status=0
        "$@" > /dev/null 2>&1 || status=$?
        if [ "$status" -ne 2 ]; then
          echo "want exit 2, got $status: $*" >&2
          exit 1
        fi
      }
      for p in ${provision}/bin/screwtape-provision ${jevProvision}/bin/screwtape-provision; do
        expect_usage "$p" bogus
        expect_usage "$p" --from-file
        expect_usage "$p" --bogus
        expect_usage "$p" fastmail fastmail
        expect_usage "$p" --from-file /nonexistent/key
      done
      expect_usage ${provision}/bin/screwtape-provision jev
      expect_usage ${jevProvision}/bin/screwtape-provision jev fastmail
      expect_usage ${jevProvision}/bin/screwtape-provision jev --from-file a --from-file b
      expect_usage ${jevProvision}/bin/screwtape-provision jev --from-file /nonexistent/key
      # A symlink source is refused (exit 2) and its target left alone; so are
      # a directory and a dash-named path.
      echo key > real-key
      ln -s real-key link-key
      expect_usage ${jevProvision}/bin/screwtape-provision jev --from-file link-key
      test -f real-key
      expect_usage ${jevProvision}/bin/screwtape-provision jev --from-file .
      expect_usage ${jevProvision}/bin/screwtape-provision jev --from-file -
      # jev without opRef and without --from-file names the missing source.
      expect_usage ${jevProvision}/bin/screwtape-provision jev
      msg=$(${jevProvision}/bin/screwtape-provision jev 2>&1 || true)
      case "$msg" in *--from-file*) ;; *) echo "want a message naming --from-file, got: $msg" >&2; exit 1 ;; esac
      test ! -e /home/operator

      touch $out
    ''
