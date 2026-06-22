/// Embedded BEAM release (zstd-compressed).
/// Built by `host/scripts/build-release.sh`.
/// On first run, extracted to a versioned cache dir (see B3).
pub const RELEASE_ZST: &[u8] = include_bytes!("../embedded/hermes-release.tar.zst");
