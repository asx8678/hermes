use std::path::Path;

fn main() {
    let embedded = Path::new("embedded/hermes-release.tar.zst");
    if embedded.exists() {
        println!("cargo:rerun-if-changed={}", embedded.display());
        // The release is embedded via include_bytes! in the binary.
        // This ensures cargo rebuilds when the release changes.
    }
}
