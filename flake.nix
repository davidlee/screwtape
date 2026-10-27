{
  description = "screwtape: Belphegor's read-only JMAP mirror (Gleam, BEAM)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # pi, the LLM gateway client, jail.nix and the quotient form wiring: one
    # pin shared with every jail.
    agents = {
      url = "github:davidlee/nix-config?dir=flakes/agents";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The form-family builder (quotient SL-003), pinned to the commit the
    # forms were built against; a published tag is CHR-003.
    quotient = {
      url = "github:davidlee/quotient/dc46a9e02fda5c73da6c986a0a5ebf3cb3e5ef4d";
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

    # quotient's per-call forms for this root (`quotient help form`): linked
    # at .quotient/forms/<capability> by `just quotient-forms`, then approved
    # with `quotient allow`. Delegates reach the model through the host LLM
    # gateway on pi's key; the agents lib supplies that wiring.
    formFamily = jailLib.quotientFormFamily {
      inherit quotient;
      packages =
        toolchain
        ++ [doctrine.packages.${system}.default]
        ++ (with pkgs; [bash findutils gnugrep gnused gawk ripgrep fd git]);
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
