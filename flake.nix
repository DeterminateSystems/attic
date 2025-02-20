{
  description = "A Nix binary cache server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";

    crane.url = "github:ipetkov/crane";

    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, nixpkgs-stable, flake-utils, crane, ... }: let
    supportedSystems = flake-utils.lib.defaultSystems ++ [ "riscv64-linux" ];

    makeCranePkgs = pkgs: let
      craneLib = crane.mkLib pkgs;
    in pkgs.callPackage ./crane.nix { inherit craneLib; };
  in flake-utils.lib.eachSystem supportedSystems (system: let
    pkgs = import nixpkgs {
      inherit system;
      overlays = [];
    };
    cranePkgs = makeCranePkgs pkgs;

    cranePkgsStatic = makeCranePkgs pkgs.pkgsStatic;

    pkgsStable = import nixpkgs-stable {
      inherit system;
      overlays = [];
    };
    cranePkgsStable = makeCranePkgs pkgsStable;

    inherit (pkgs) lib;
  in rec {
    packages = {
      default = packages.attic;

      inherit (cranePkgs) attic attic-client attic-server;

      attic-static = cranePkgsStatic.attic;
      attic-client-static = cranePkgsStatic.attic-client;
      attic-server-static = cranePkgsStatic.attic-server;

      attic-ci-installer = pkgs.callPackage ./ci-installer.nix {
        inherit self;
      };

      book = pkgs.callPackage ./book {
        attic = packages.attic;
      };
   } // (lib.optionalAttrs pkgs.stdenv.isLinux {
      attic-server-image = pkgs.dockerTools.buildImage {
        name = "attic-server";
        tag = "main";
        copyToRoot = [
          # Debugging utilities for `fly ssh console`
          pkgs.busybox
          packages.attic-server

          # Now required by the fly.io sshd
          pkgs.dockerTools.fakeNss
        ];
        config = {
          Entrypoint = [ "${packages.attic-server}/bin/atticd" ];
          Env = [
            "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          ];
        };
      };
    });

    devShells = {
      default = pkgs.mkShell {
        inputsFrom = with packages; [ attic book ];
        nativeBuildInputs = with pkgs; [
          rustc
          rust-analyzer

          rustfmt clippy
          cargo-expand cargo-outdated cargo-edit
          tokio-console

          sqlite-interactive

          editorconfig-checker

          flyctl

          wrk
        ] ++ (lib.optionals pkgs.stdenv.isLinux [
          linuxPackages.perf
        ]);

        NIX_PATH = "nixpkgs=${pkgs.path}";
        RUST_SRC_PATH = "${pkgs.rustPlatform.rustcSrc}/library";

        ATTIC_DISTRIBUTOR = "dev";
      };

      demo = pkgs.mkShell {
        nativeBuildInputs = [
          packages.default
        ];

        shellHook = ''
          >&2 echo
          >&2 echo '🚀 Run `atticd` to get started!'
          >&2 echo
        '';
      };
    };
    devShell = devShells.default;

    internal = {
      inherit (cranePkgs) attic-tests cargoArtifacts;
    };

    checks = let
      makeIntegrationTests = pkgs: import ./integration-tests {
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };
        flake = self;
      };
      unstableTests = makeIntegrationTests pkgs;
      stableTests = lib.mapAttrs' (name: lib.nameValuePair "stable-${name}") (makeIntegrationTests pkgsStable);
    in lib.optionalAttrs pkgs.stdenv.isLinux (unstableTests // stableTests);
  }) // {
    overlays = {
      default = final: prev: let
        cranePkgs = makeCranePkgs final;
      in {
        inherit (cranePkgs) attic attic-client attic-server;
      };
    };

    nixosModules = {
      atticd = {
        imports = [
          ./nixos/atticd.nix
        ];

        services.atticd.useFlakeCompatOverlay = false;

        nixpkgs.overlays = [
          self.overlays.default
        ];
      };
    };
  };
}
