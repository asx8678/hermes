//! Embedded app source (zstd-compressed tarball).
//!
//! When the host ships as a single binary with no source tree, this embeds the
//! Elixir project (mix.exs, lib/, priv/, config/) so it can be extracted to
//! `~/.hermes/app-src/<version>/` and used for system-runtime launches
//! (`mix phx.server` under the user's Erlang/Elixir via mise or PATH).

use anyhow::{Context, Result};
use rand::RngCore;
use std::path::{Path, PathBuf};

/// Embedded app source tarball (zstd-compressed).
pub const APP_SOURCE_ZST: &[u8] = include_bytes!("../embedded/hermes-app-source.tar.zst");

/// Versioned cache dir name — matches the host crate version so a binary
/// upgrade re-extracts fresh source.
pub const SOURCE_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Extract the embedded app source to `cache_root/<version>/` and return that
/// path. Idempotent: if the marker file exists, returns immediately.
pub async fn extract(cache_root: impl AsRef<Path>) -> Result<PathBuf> {
    let cache_root = cache_root.as_ref();
    let cache_dir = cache_root.join(SOURCE_VERSION);
    let marker = cache_dir.join(".hermes-app-source-extracted");

    if marker.exists() && cache_dir.join("mix.exs").exists() {
        return Ok(cache_dir);
    }

    tokio::fs::create_dir_all(cache_root)
        .await
        .with_context(|| format!("creating app-source cache root {}", cache_root.display()))?;

    let tmp_name = format!(".app-src-extract-{}", random_hex(8));
    let tmp_dir = cache_root.join(&tmp_name);

    tokio::task::spawn_blocking({
        let tmp_dir = tmp_dir.clone();
        move || -> Result<()> {
            let _ = std::fs::remove_dir_all(&tmp_dir);
            std::fs::create_dir_all(&tmp_dir)
                .with_context(|| format!("creating temp extract dir {}", tmp_dir.display()))?;
            let decoder = zstd::Decoder::new(APP_SOURCE_ZST)
                .context("creating zstd decoder for embedded app source")?;
            let mut archive = tar::Archive::new(decoder);
            archive
                .unpack(&tmp_dir)
                .with_context(|| format!("unpacking app source into {}", tmp_dir.display()))?;
            Ok(())
        }
    })
    .await
    .context("app source extraction task panicked")??;

    if cache_dir.exists() {
        let _ = tokio::fs::remove_dir_all(&cache_dir).await;
    }

    tokio::fs::rename(&tmp_dir, &cache_dir)
        .await
        .with_context(|| {
            format!(
                "renaming {} to {}",
                tmp_dir.display(),
                cache_dir.display()
            )
        })?;

    tokio::fs::write(&marker, b"")
        .await
        .context("writing app source extraction marker")?;

    Ok(cache_dir)
}

fn random_hex(byte_len: usize) -> String {
    let mut buf = vec![0u8; byte_len];
    rand::thread_rng().fill_bytes(&mut buf);
    hex::encode(&buf)
}
