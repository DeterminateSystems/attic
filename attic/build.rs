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

    println!("cargo:rerun-if-changed=src/nix_store/bindings");

    cxx_build::bridge("src/nix_store/bindings/mod.rs")
        .file("src/nix_store/bindings/nix.cpp")
        .std("c++2a")
        .includes(deps.all_include_paths())
        .flag("-include")
        .flag("config-store.hh")
        .flag("-include")
        .flag("config-main.hh")
        .compile("nixbinding");
}
