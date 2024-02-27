//! Build script.
//!
//! We link against libnixstore to perform actions on the Nix Store.

fn main() {
    #[cfg(feature = "nix_store")]
    build_bridge();
}

#[cfg(feature = "nix_store")]
fn build_bridge() {
    let nix_include_dir = &pkg_config::probe_library("nix-store")
        .unwrap()
        .include_paths[0];

    cxx_build::bridge("src/nix_store/bindings/mod.rs")
        .file("src/nix_store/bindings/nix.cpp")
        .flag("-std=c++2a")
        .flag("-O2")
        .flag("-include")
        .flag("nix/config.h")
        .flag("-I")
        .flag(&nix_include_dir.to_string_lossy())
        .compile("nixbinding");

    println!("cargo:rerun-if-changed=src/nix_store/bindings");

    // the -l flags must be after -lnixbinding
    pkg_config::Config::new()
        .atleast_version("2.4")
        .probe("nix-store")
        .unwrap();

    pkg_config::Config::new()
        .atleast_version("2.4")
        .probe("nix-main")
        .unwrap();
}
