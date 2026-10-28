# Home Manager module: Screwtape as a systemd user oneshot under the operator's
# uid, its store under xdg.stateHome (DEC-004, DEC-016, DEC-017; design § 5.4).
# `self` is this flake, for the default package.
self: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.screwtape;
  inherit (lib) mkOption types;

  # One name per credential: the config's credential_name, the LoadCredentialEncrypted
  # id and the name systemd-creds embeds (it must match).
  credential = "fastmail";
  jevCredential = "jev";
  # Relative to %E, the user manager's xdg.configHome (asserted below).
  credentialPath = name: "credstore.encrypted/screwtape.${name}";
  # Absolute, for the wrapper's transient unit and the provision script.
  storedCredential = name: "${config.xdg.configHome}/${credentialPath name}";

  # The two crash-dump channels closed (I1): the sync unit sets them as unit
  # options and the Jev wrapper's transient unit as systemd-run flags.
  crashDump = {
    limitCore = "0";
    erlCrashDumpSeconds = "0";
  };

  # The unit's StateDirectory, under xdg.stateHome (asserted below).
  storeDir = "${config.xdg.stateHome}/screwtape";

  # The config holds no secret, so it lives in the store (DEC-009).
  configFile = pkgs.writeTextFile {
    name = "screwtape.json";
    text = builtins.toJSON {
      session_url = cfg.sessionUrl;
      credential_name = credential;
      store_path = "${storeDir}/mail.sqlite3";
      window = {
        inherit (cfg.window) mailboxes;
        max_age_days = cfg.window.maxAgeDays;
        max_messages = cfg.window.maxMessages;
        retain_messages = cfg.window.retainMessages;
      };
      max_body_bytes = cfg.maxBodyBytes;
      max_pages = cfg.maxPages;
      max_total_bytes = cfg.maxTotalBytes;
      request_timeout_ms = cfg.requestTimeoutMs;
      ca_file = cfg.caFile;
      jev =
        if cfg.jev == null
        then null
        else {
          base_url = cfg.jev.baseUrl;
          credential_name = jevCredential;
          inherit (cfg.jev) model;
        };
    };
    # The program's own parser judges the config, so no rule is restated here:
    # it exits 2 on a rejected config, and 1 on an accepted one, since the
    # store does not exist in the build sandbox.
    checkPhase = ''
      status=0
      HOME="$TMPDIR" ${cfg.package}/bin/screwtape --config "$target" mailboxes || status=$?
      if [ "$status" -eq 2 ]; then
        echo "services.screwtape: the program rejects the generated config" >&2
        exit 1
      fi
    '';
  };

  screwtapeCmd = "${cfg.package}/bin/screwtape --config ${configFile}";

  # Only adds --config (DEC-017); the unit runs `sync` through it too (I9).
  # With Jev configured, `classify` (but not `classify --state`, which never
  # reaches the gateway) runs in a transient unit that loads the encrypted key:
  # only the credential's path is in argv; the program reads
  # $CREDENTIALS_DIRECTORY/jev inside it (DEC-038).
  jevRun = lib.concatStringsSep " " [
    "${pkgs.systemd}/bin/systemd-run --user --pipe --quiet --wait --collect"
    "-p ${lib.escapeShellArg "LoadCredentialEncrypted=${jevCredential}:${storedCredential jevCredential}"}"
    "-p LimitCORE=${crashDump.limitCore} -E ERL_CRASH_DUMP_SECONDS=${crashDump.erlCrashDumpSeconds}"
  ];
  wrapper = pkgs.writeShellApplication {
    name = "screwtape";
    text =
      lib.optionalString (cfg.jev != null) ''
        if [ "''${1-}" = classify ] && ! { [ "$#" -eq 2 ] && [ "$2" = --state ]; }; then
          exec ${jevRun} ${screwtapeCmd} "$@"
        fi
      ''
      + ''
        exec ${screwtapeCmd} "$@"
      '';
  };

  # The credentials each provision run may store, and where each token comes
  # from by default (jev has no default source when opRef is null).
  provisionable =
    [
      {
        name = credential;
        opRef = cfg.opRef;
      }
    ]
    ++ lib.optional (cfg.jev != null) {
      name = jevCredential;
      opRef = cfg.jev.opRef;
    };
  provisionCase = c: ''
    ${c.name})
      stored=${lib.escapeShellArg (storedCredential c.name)}
      op_ref=${lib.escapeShellArg (toString c.opRef)}
      encrypt() { systemd-creds encrypt --user --name=${c.name} "$@" "$staged"; }
      ;;
  '';

  # The gateway's credentials procedure at user scope (design § 5.4): the
  # token goes from op (or a file) straight into systemd-creds, never into
  # argv, a variable or a clear staged file; the staged credential replaces the
  # stored one only when both steps succeed. A --from-file source is removed
  # once stored.
  provision = pkgs.writeShellApplication {
    name = "screwtape-provision";
    runtimeInputs = [pkgs.coreutils pkgs.systemd];
    text = ''
      umask 077
      usage() {
        echo "usage: screwtape-provision [${lib.concatMapStringsSep "|" (c: c.name) provisionable}] [--from-file <path>]" >&2
        exit 2
      }
      name=""
      from=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --from-file)
            if [ "$#" -lt 2 ] || [ -z "$2" ] || [ -n "$from" ]; then usage; fi
            from=$2
            shift 2
            ;;
          ${lib.concatMapStringsSep "|" (c: c.name) provisionable})
            if [ -n "$name" ]; then usage; fi
            name=$1
            shift
            ;;
          *) usage ;;
        esac
      done
      name=''${name:-${credential}}
      case "$name" in
      ${lib.concatMapStrings provisionCase provisionable}esac

      if [ -n "$from" ]; then
        # No symlink, and never the stored credential itself (resolved); the
        # resolved absolute path is what encrypt and rm see, so it can't be
        # "-" or start with "-".
        if [ -L "$from" ] || [ ! -f "$from" ] || [ ! -r "$from" ]; then
          echo "screwtape-provision: $from is not a readable regular file (symlinks refused)" >&2
          exit 2
        fi
        from=$(realpath -e -- "$from")
        if [ "$from" = "$(realpath -m -- "$stored")" ]; then
          echo "screwtape-provision: $from is the stored credential itself" >&2
          exit 2
        fi
      elif [ -z "$op_ref" ]; then
        echo "screwtape-provision: $name has no opRef; pass --from-file <path>" >&2
        exit 2
      fi

      mkdir -p "$(dirname "$stored")"
      # A private staging directory beside the stored file (same filesystem, so
      # the final mv is atomic), per run so concurrent runs can't share it.
      # Whatever happens, it is removed (after mv it is empty); a signal exits
      # too, so the trap runs.
      stage=""
      trap 'if [ -n "$stage" ]; then rm -rf -- "$stage"; fi' EXIT
      trap 'exit 130' INT TERM HUP
      stage=$(mktemp -d -- "$stored.XXXXXX")
      staged="$stage/staged"

      if [ -n "$from" ]; then
        if ! encrypt "$from"; then
          echo "screwtape-provision: systemd-creds encrypt failed; stored credential unchanged" >&2
          exit 1
        fi
      else
        # setgid onepassword-cli: the plain op binary can't reach the app.
        set +o errexit
        /run/wrappers/bin/op read --no-newline "$op_ref" | encrypt -
        steps=("''${PIPESTATUS[@]}")
        set -o errexit
        if [ "''${steps[0]}" -ne 0 ] || [ "''${steps[1]}" -ne 0 ]; then
          echo "screwtape-provision: op read exit ''${steps[0]}, systemd-creds encrypt exit ''${steps[1]}; stored credential unchanged" >&2
          exit 1
        fi
      fi
      if ! mv -fT -- "$staged" "$stored"; then
        echo "screwtape-provision: could not move the staged credential into place; stored credential unchanged" >&2
        exit 1
      fi
      if [ -n "$from" ] && ! rm -f -- "$from"; then
        echo "screwtape-provision: credential $name stored; could not remove $from, delete it yourself" >&2
        exit 1
      fi

      if [ "$name" != ${credential} ]; then
        echo "screwtape-provision: credential $name stored"
        exit 0
      fi
      systemctl --user reset-failed screwtape.service 2>/dev/null || true
      if systemctl --user start screwtape.service; then
        echo "screwtape-provision: credential stored; first sync succeeded"
      else
        echo "screwtape-provision: credential stored; sync failed, see journalctl --user -u screwtape" >&2
        exit 1
      fi
    '';
  };
in {
  options.services.screwtape = {
    enable = lib.mkEnableOption "Screwtape, the read-only JMAP mirror";

    configFile = mkOption {
      type = types.package;
      internal = true;
      readOnly = true;
      description = "The generated config, as the wrapper passes it.";
    };

    storeDir = mkOption {
      type = types.str;
      internal = true;
      readOnly = true;
      description = "The store's directory. A reader, jailed or not, needs it writable (DEC-031).";
    };

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "screwtape.packages.\${system}.default";
      description = "The Screwtape package.";
    };

    opRef = mkOption {
      type = types.str;
      example = "op://Private/Fastmail read-only/credential";
      description = "1Password reference to the Fastmail API token, read by screwtape-provision.";
    };

    jev = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          baseUrl = mkOption {
            type = types.str;
            default = "https://api.typesafe.ai";
            description = "The Jev gateway's base URL. For the local relay, http://127.0.0.1:<relayPort> (DEC-033); the program validates it.";
          };
          model = mkOption {
            type = types.str;
            example = "typesafe/jev-1.14.0";
            description = "The pinned Jev model version; no default, the operator chooses.";
          };
          opRef = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "1Password reference to the Jev key, read by `screwtape-provision jev` when no --from-file is given.";
          };
        };
      });
      default = null;
      description = "The Jev classification gateway; null disables the `classify` key ingress (DEC-038).";
    };

    sessionUrl = mkOption {
      type = types.str;
      default = "https://api.fastmail.com/jmap/session";
      description = "The JMAP session resource (https only).";
    };

    window = {
      mailboxes = mkOption {
        type = types.nonEmptyListOf types.str;
        default = ["inbox"];
        description = "Mailboxes to mirror, each matched by role first, then by name.";
      };
      maxAgeDays = mkOption {
        type = types.nullOr types.ints.positive;
        default = 30;
        description = "Mirror messages received within this many days.";
      };
      maxMessages = mkOption {
        type = types.nullOr types.ints.positive;
        default = 2000;
        description = "Mirror at most this many messages, newest first.";
      };
      retainMessages = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = "Keep at most this many messages in the store, newest first; requires maxMessages and must be at least it. Null keeps exactly the window.";
      };
    };

    maxBodyBytes = mkOption {
      type = types.ints.positive;
      default = 262144;
      description = "Bound on one message's stored body text, summed over its parts.";
    };

    maxPages = mkOption {
      type = types.ints.positive;
      default = 20;
      description = "Bound on Email/query pages, and on Email/changes pages, per sync.";
    };

    maxTotalBytes = mkOption {
      type = types.ints.positive;
      default = 268435456;
      description = "Bound on every HTTP response body received in one sync, summed.";
    };

    requestTimeoutMs = mkOption {
      type = types.ints.positive;
      default = 30000;
      description = "Per-request timeout.";
    };

    caFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Absolute path of a CA bundle to trust instead of the system store (DEC-018).";
    };

    onCalendar = mkOption {
      type = types.str;
      default = "*:0/15";
      description = "When the timer runs a sync (systemd.time(7)).";
    };

    timeoutStartSec = mkOption {
      type = types.str;
      default = "5min";
      description = "TimeoutStartSec of the sync unit.";
    };

    memoryMax = mkOption {
      type = types.str;
      default = "1G";
      description = "MemoryMax of the sync unit: contains the process if the application bounds fail.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.screwtape = {inherit configFile storeDir;};

    # The unit's StateDirectory and %E resolve from the user manager's own
    # defaults, not from xdg: the two must agree (RV-001 F-31).
    assertions = [
      {
        assertion = config.xdg.stateHome == "${config.home.homeDirectory}/.local/state";
        message = "services.screwtape: xdg.stateHome must be its default, ~/.local/state, where the unit's StateDirectory lives (RV-001 F-31).";
      }
      {
        assertion = config.xdg.configHome == "${config.home.homeDirectory}/.config";
        message = "services.screwtape: xdg.configHome must be its default, ~/.config, the unit's %E, where screwtape-provision stores the credential.";
      }
    ];

    home.packages = [wrapper provision];

    systemd.user.services.screwtape = {
      Unit.Description = "Screwtape: sync the JMAP mirror";
      Service = {
        Type = "oneshot";
        ExecStart = "${wrapper}/bin/screwtape sync";
        StateDirectory = "screwtape";
        StateDirectoryMode = "0700";
        # %E is $XDG_CONFIG_HOME in a user unit; screwtape-provision writes it.
        LoadCredentialEncrypted = "${credential}:%E/${credentialPath credential}";
        TimeoutStartSec = cfg.timeoutStartSec;
        MemoryMax = cfg.memoryMax;
        # The subset of hardening that works in a user unit (design § 5.4).
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "tmpfs";
        RestrictAddressFamilies = "AF_UNIX AF_INET AF_INET6";
        SystemCallFilter = "@system-service";
        UMask = "0077";
        # Close the crash-dump channels (I1).
        LimitCORE = crashDump.limitCore;
        Environment = ["ERL_CRASH_DUMP_SECONDS=${crashDump.erlCrashDumpSeconds}"];
      };
    };

    systemd.user.timers.screwtape = {
      Unit.Description = "Screwtape: periodic sync";
      Timer = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
      };
      Install.WantedBy = ["timers.target"];
    };
  };
}
