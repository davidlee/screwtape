{
  description = "screwtape: Belphegor's read-only JMAP mirror (Gleam, BEAM)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
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

    # What the project needs to build and test.
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
  in {
    homeManagerModules.default = import ./nix/module.nix self;

    packages.${system} = {
      screwtape = screwtape false;
      default = screwtape false;

      # The producer contract of the dev-envs consumer (flakes:SL-022): the
      # tools the gate needs. Doctrine is not here; the jails bind the host's.
      dev-tools = pkgs.buildEnv {
        name = "screwtape-dev-tools";
        paths = toolchain;
      };
      # What the room takes: `dev-tools` plus Doctrine, as a room has no host install
      # (flakes:DEC-130).
      capsule-tools = pkgs.buildEnv {
        name = "screwtape-capsule-tools";
        paths = toolchain ++ [doctrine.packages.${system}.default];
        ignoreCollisions = true;
      };
    };

    checks.${system} = {
      gleam-test = screwtape true;
      module-eval = import ./nix/module-eval.nix {
        inherit self pkgs home-manager;
      };
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = toolchain;
    };
  };
}
