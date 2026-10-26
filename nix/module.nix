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

  # One name for the credential: the config's credential_name, the unit's
  # LoadCredentialEncrypted id and the name systemd-creds embeds (it must match).
  credential = "fastmail";

  # The config holds no secret, so it lives in the store (DEC-009).
  configFile = pkgs.writeText "screwtape.json" (builtins.toJSON {
    session_url = cfg.sessionUrl;
    credential_name = credential;
    store_path = "${config.xdg.stateHome}/screwtape/mail.sqlite3";
    window = {
      inherit (cfg.window) mailboxes;
      max_age_days = cfg.window.maxAgeDays;
      max_messages = cfg.window.maxMessages;
    };
    max_body_bytes = cfg.maxBodyBytes;
    max_pages = cfg.maxPages;
    max_total_bytes = cfg.maxTotalBytes;
    request_timeout_ms = cfg.requestTimeoutMs;
    ca_file = cfg.caFile;
  });

  # Only adds --config (DEC-017); the unit runs `sync` through it too (I9).
  wrapper = pkgs.writeShellApplication {
    name = "screwtape";
    text = ''
      exec ${cfg.package}/bin/screwtape --config ${configFile} "$@"
    '';
  };

  # The gateway's credentials procedure at user scope (design § 5.4): the
  # token goes from op straight into systemd-creds, never into argv, a
  # variable or a clear file; the staged credential replaces the stored one
  # only when both steps succeed.
  provision = pkgs.writeShellApplication {
    name = "screwtape-provision";
    runtimeInputs = [pkgs.coreutils pkgs.systemd];
    text = ''
      umask 077
      dir="''${XDG_CONFIG_HOME:-$HOME/.config}/credstore.encrypted"
      stored="$dir/screwtape.${credential}"
      staged="$stored.new"
      mkdir -p "$dir"

      # setgid onepassword-cli: the plain op binary can't reach the app.
      set +o errexit
      /run/wrappers/bin/op read --no-newline ${lib.escapeShellArg cfg.opRef} \
        | systemd-creds encrypt --user --name=${credential} - "$staged"
      steps=("''${PIPESTATUS[@]}")
      set -o errexit
      if [ "''${steps[0]}" -ne 0 ] || [ "''${steps[1]}" -ne 0 ]; then
        rm -f -- "$staged"
        echo "screwtape-provision: op read exit ''${steps[0]}, systemd-creds encrypt exit ''${steps[1]}; stored credential unchanged" >&2
        exit 1
      fi
      mv -f -- "$staged" "$stored"

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
    };

    maxBodyBytes = mkOption {
      type = types.ints.positive;
      default = 262144;
      description = "Bound on one message's stored body text, summed over its parts.";
    };

    maxPages = mkOption {
      type = types.ints.positive;
      default = 20;
      description = "Bound on Email/query pages per sync.";
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
    # The unit's StateDirectory resolves from the user manager's own default,
    # not from xdg.stateHome: the two must agree (RV-001 F-31).
    assertions = [
      {
        assertion = config.xdg.stateHome == "${config.home.homeDirectory}/.local/state";
        message = "services.screwtape: xdg.stateHome must be its default, ~/.local/state, where the unit's StateDirectory lives (RV-001 F-31).";
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
        LoadCredentialEncrypted = "${credential}:%E/credstore.encrypted/screwtape.${credential}";
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
        LimitCORE = 0;
        Environment = ["ERL_CRASH_DUMP_SECONDS=0"];
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
