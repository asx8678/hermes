use std::path::Path;

fn main() {
    let embedded = Path::new("embedded/hermes-release.tar.zst");
    if embedded.exists() {
        println!("cargo:rerun-if-changed={}", embedded.display());
        // The release is embedded via include_bytes! in the binary.
        // This ensures cargo rebuilds when the release changes.
    }
    let app_source = Path::new("embedded/hermes-app-source.tar.zst");
    if app_source.exists() {
        println!("cargo:rerun-if-changed={}", app_source.display());
    }
}
