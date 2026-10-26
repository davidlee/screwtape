{
  description = "screwtape: Belphegor's read-only JMAP mirror (Gleam, BEAM)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # pi, the LLM gateway client and jail.nix: one pin shared with every jail.
    agents = {
      url = "github:davidlee/nix-config?dir=flakes/agents";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    jail-nix.follows = "agents/jail-nix";
    # The form-family builder (quotient SL-003) is not on a published tag yet:
    # pinned to the local commit until one is (CHR-001).
    quotient = {
      url = "git+file:///home/david/dev/quotient?rev=dc46a9e02fda5c73da6c986a0a5ebf3cb3e5ef4d";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    doctrine.url = "github:davidlee/doctrine";
    nix-gleam = {
      url = "github:arnarg/nix-gleam";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # For checks.module-eval only: consumers bring their own Home Manager.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    agents,
    jail-nix,
    quotient,
    doctrine,
    nix-gleam,
    home-manager,
    ...
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    screwtape = doCheck:
      pkgs.callPackage ./nix/package.nix {
        inherit (nix-gleam.packages.${system}) buildGleamApplication;
        inherit doCheck;
      };
    jailLib = agents.lib.${system}.mkJailedAgents {};

    # What the project needs to build and test, in the devshell and in a
    # delegate's jail alike.
    toolchain = with pkgs; [
      gleam
      beamPackages.erlang
      beamPackages.rebar3
      sqlite
      just
      # sqlight's esqlite NIF compiles through rebar3's pc plugin.
      gcc
      gnumake
    ];

    # Delegates reach the model through the host LLM gateway on pi's key: the
    # URL is a literal, the key is read at launch outside the jail, and pi's
    # provider list is bound read-only.
    gateway = jailLib.gatewayClient "pi";
    gatewayModels = (import "${agents}/gateway.nix").models;

    # quotient's per-call forms for this root (`quotient help form`): linked
    # at .quotient/forms/<capability> by `just quotient-forms`, then approved
    # with `quotient allow`.
    formFamily = quotient.lib.mkFormFamily {
      inherit pkgs jail-nix;
      pi = jailLib.unjailed.pi;
      packages =
        toolchain
        ++ [doctrine.packages.${system}.default]
        ++ (with pkgs; [bash findutils gnugrep gnused gawk ripgrep fd git]);
      env.LLM_GATEWAY_URL = gateway.url;
      secretEnv.LLM_GATEWAY_KEY = ''$(< "${gateway.keyFile}")'';
      piFiles."models.json" =
        pkgs.writeText "pi-gateway-models.json"
        (builtins.toJSON (jailLib.piGatewayConfig gateway.url gatewayModels));
    };
  in {
    homeManagerModules.default = import ./nix/module.nix self;

    packages.${system} = {
      screwtape = screwtape false;
      default = screwtape false;
      quotient-read = formFamily.read;
      quotient-write = formFamily.write;
    };

    checks.${system} = {
      gleam-test = screwtape true;
      module-eval = import ./nix/module-eval.nix {
        inherit self pkgs home-manager;
      };
      quotient-forms = quotient.lib.checkFormFamily {
        inherit pkgs;
        family = formFamily;
      };
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = toolchain ++ [doctrine.packages.${system}.default];
    };
  };
}
