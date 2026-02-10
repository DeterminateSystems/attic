//! Build script.
//!
//! We link against libnixstore to perform actions on the Nix Store.

fn main() {
    #[cfg(feature = "nix_store")]
    build_bridge();
}

#[cfg(feature = "nix_store")]
fn build_bridge() {
    let deps = system_deps::Config::new().probe().unwrap();

    let mut build = cxx_build::bridge("src/nix_store/bindings/mod.rs");
    build
        .file("src/nix_store/bindings/nix.cpp")
        .flag("-std=c++23")
        .flag("-O2")
        .includes(deps.all_include_paths());

    build.compile("nixbinding");

    println!("cargo:rerun-if-changed=src/nix_store/bindings");
}
