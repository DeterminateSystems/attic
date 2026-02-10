{ stdenv
, lib
, buildPackages
, craneLib
, rust
, runCommand
, writeClosure
, pkg-config
, installShellFiles
, jq
, lld

, nix-packages
, boost
, libarchive

, extraPackageArgs ? {}
}:

let
  version = "0.1.0";

  ignoredPaths = [
    ".ci"
    ".github"
    "book"
    "flake"
    "integration-tests"
    "nixos"
    "target"
  ];

  src = lib.cleanSourceWith {
    filter = name: type: !(type == "directory" && builtins.elem (baseNameOf name) ignoredPaths);
    src = lib.cleanSource ./.;
  };

  nativeBuildInputs = [
    pkg-config
    installShellFiles
  ];

  buildInputs = [
    nix-packages.nix-util-static
    nix-packages.nix-store-static
    nix-packages.nix-main-static
    nix-packages.nix-expr-static
    boost
  ];

  rustTargetSpec = stdenv.hostPlatform.rust.rustcTargetSpec;
  rustTargetSpecEnv = lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] rustTargetSpec);

  isCross = stdenv.hostPlatform != stdenv.buildPlatform;

  crossArgs = lib.optionalAttrs (isCross) {
    doIncludeCrossToolchainEnv = false;
    depsBuildBuild = [
      buildPackages.stdenv.cc
      lld
    ];

    CARGO_BUILD_TARGET = rustTargetSpec;
    "CARGO_TARGET_${rustTargetSpecEnv}_LINKER" = "${stdenv.cc.targetPrefix}cc";
    RUSTFLAGS = "-C relocation-model=static -Clink-arg=-fuse-ld=lld";
    SYSTEM_DEPS_LINK = "static";
  };

  extraArgs = crossArgs // extraPackageArgs;

  cargoArtifacts = craneLib.buildDepsOnly ({
    pname = "attic";
    inherit src version nativeBuildInputs buildInputs;

    # By default it's "use-symlink", which causes Crane's `inheritCargoArtifactsHook`
    # to copy the artifacts using `cp --no-preserve=mode` which breaks the executable
    # bit of bindgen's build-script binary.
    #
    # With `use-zstd`, the cargo artifacts are archived in a `tar.zstd`. This is
    # actually set if you use `buildPackage` without passing `cargoArtifacts`.
    installCargoArtifactsMode = "use-zstd";
  } // extraArgs);

  mkAttic = {
    packages,
  }: let
    cargoPackageArgs = map (p: "-p ${p}") packages;
  in craneLib.buildPackage ({
    pname = "attic";
    inherit src version nativeBuildInputs buildInputs cargoArtifacts;

    ATTIC_DISTRIBUTOR = "attic";

    # See comment in `attic-tests`
    doCheck = false;

    cargoExtraArgs = lib.concatStringsSep " " cargoPackageArgs;

    postInstall = lib.optionalString (stdenv.hostPlatform == stdenv.buildPlatform) ''
      if [[ -f $out/bin/attic ]]; then
        installShellCompletion --cmd attic \
          --bash <($out/bin/attic gen-completions bash) \
          --zsh <($out/bin/attic gen-completions zsh) \
          --fish <($out/bin/attic gen-completions fish)
      fi
    '';

  } // extraArgs);

  attic = mkAttic {
    packages = ["attic-client" "attic-server"];
  };

  # Client-only package.
  attic-client = mkAttic {
    packages = ["attic-client"];
  };

  # Server-only package with fat LTO enabled.
  #
  # Because of Cargo's feature unification, the common `attic` crate always
  # has the `nix_store` feature enabled if the client and server are built
  # together, leading to `atticd` linking against `libnixstore` as well. This
  # package is slimmer with more optimization.
  #
  # We don't enable fat LTO in the default `attic` package since it
  # dramatically increases build time.
  attic-server = craneLib.buildPackage ({
    pname = "attic-server";

    # We don't pull in the common cargoArtifacts because the feature flags
    # and LTO configs are different
    inherit src version nativeBuildInputs buildInputs;

    # See comment in `attic-tests`
    doCheck = false;

    cargoExtraArgs = "-p attic-server";

    CARGO_PROFILE_RELEASE_LTO = "fat";
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "1";

    meta = {
      mainProgram = "atticd";
    };
  } // extraArgs);

  # Attic interacts with Nix directly and its tests require trusted-user access
  # to nix-daemon to import NARs, which is not possible in the build sandbox.
  # In the CI pipeline, we build the test executable inside the sandbox, then
  # run it outside.
  attic-tests = craneLib.mkCargoDerivation ({
    pname = "attic-tests";

    inherit src version buildInputs cargoArtifacts;

    nativeBuildInputs = nativeBuildInputs ++ [ jq ];

    doCheck = true;

    buildPhaseCargoCommand = "";
    checkPhaseCargoCommand = "cargoWithProfile test --no-run --message-format=json >cargo-test.json";
    doInstallCargoArtifacts = false;

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin
      jq -r 'select(.reason == "compiler-artifact" and .target.test and .executable) | .executable' <cargo-test.json | \
        xargs -I {} cp {} $out/bin

      runHook postInstall
    '';
  } // extraArgs);
in {
  inherit cargoArtifacts attic attic-client attic-server attic-tests;
}
