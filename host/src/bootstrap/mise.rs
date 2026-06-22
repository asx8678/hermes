//! App-local management of the [`mise`](https://mise.jdx.dev) runtime manager.
//!
//! We download a single, static `mise` binary into `~/.hermes/bin/` over HTTP
//! (no shell scripts), then drive it to install and keep Erlang/OTP + Elixir
//! up to date inside an app-local data dir. Nothing is installed system-wide
//! and no `sudo` is required.

use super::detect::{self, Detected};
use anyhow::{anyhow, bail, Context, Result};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::mpsc::UnboundedSender;

/// Channel onto which progress/log lines are pushed for the setup UI to render.
pub type LogSink = UnboundedSender<String>;

fn log(sink: &LogSink, line: impl Into<String>) {
    // The receiver may have gone away if the UI closed; that's not fatal.
    let _ = sink.send(line.into());
}

/// The tool specs mise installs and keeps pinned. `@latest` lets `mise upgrade`
/// move them forward over time, satisfying the "keep them updated" requirement.
pub const ERLANG_SPEC: &str = "erlang@latest";
pub const ELIXIR_SPEC: &str = "elixir@latest";

/// An app-local mise installation rooted under the Hermes home directory.
#[derive(Debug, Clone)]
pub struct Mise {
    bin: PathBuf,
    data_dir: PathBuf,
    config_file: PathBuf,
}

impl Mise {
    /// Resolve the standard app-local paths under `home` (typically `~/.hermes`).
    pub fn new(home: &Path) -> Self {
        let bin_name = if cfg!(windows) { "mise.exe" } else { "mise" };
        Mise {
            bin: home.join("bin").join(bin_name),
            data_dir: home.join("mise"),
            config_file: home.join("mise").join("config.toml"),
        }
    }

    /// True once the mise binary has been downloaded.
    pub fn is_installed(&self) -> bool {
        self.bin.exists()
    }

    /// Standard environment that pins mise to our app-local dirs and runs it
    /// non-interactively.
    fn env(&self) -> Vec<(&'static str, String)> {
        vec![
            ("MISE_DATA_DIR", self.data_dir.display().to_string()),
            (
                "MISE_GLOBAL_CONFIG_FILE",
                self.config_file.display().to_string(),
            ),
            // Never block on a prompt — we drive everything programmatically.
            ("MISE_YES", "1".to_string()),
        ]
    }

    /// A `mise` command pre-loaded with the app-local environment.
    fn command(&self) -> Command {
        let mut cmd = Command::new(&self.bin);
        for (k, v) in self.env() {
            cmd.env(k, v);
        }
        cmd
    }

    /// A `mise exec -- ` command prefix. The caller appends the program and its
    /// arguments (e.g. `.arg("mix").arg("phx.server")`). Tools installed by mise
    /// are placed on `PATH` for the duration of the child.
    pub fn exec(&self) -> Command {
        let mut cmd = self.command();
        cmd.arg("exec").arg("--");
        cmd
    }

    /// Download and install the mise binary if it isn't already present.
    pub async fn ensure_installed(&self, sink: &LogSink) -> Result<()> {
        if self.is_installed() {
            return Ok(());
        }
        log(sink, "Fetching the mise runtime manager…");

        let asset = resolve_latest_asset(sink).await?;
        log(sink, format!("Downloading {}", asset.name));
        let bytes = download(&asset.url).await?;

        log(sink, "Extracting mise…");
        let dest = self.bin.clone();
        let name = asset.name.clone();
        tokio::task::spawn_blocking(move || extract_mise(&name, &bytes, &dest))
            .await
            .context("mise extraction task panicked")??;

        log(sink, "mise installed.");
        Ok(())
    }

    /// Install (or pin) Erlang/OTP + Elixir into the app-local data dir,
    /// streaming mise's own progress output to the UI.
    pub async fn install_runtime(&self, sink: &LogSink) -> Result<()> {
        if let Some(parent) = self.config_file.parent() {
            tokio::fs::create_dir_all(parent).await.ok();
        }
        log(sink, "Installing Erlang/OTP and Elixir (this can take a while)…");
        let mut cmd = self.command();
        cmd.arg("use").arg("--global").arg(ERLANG_SPEC).arg(ELIXIR_SPEC);
        run_streaming(cmd, sink)
            .await
            .context("`mise use --global` failed")
    }

    /// Upgrade the pinned tools to the latest matching versions. Used to keep
    /// the runtime current on subsequent launches.
    pub async fn upgrade(&self, sink: &LogSink) -> Result<()> {
        log(sink, "Checking for Erlang/Elixir updates…");
        let mut cmd = self.command();
        cmd.arg("upgrade");
        run_streaming(cmd, sink)
            .await
            .context("`mise upgrade` failed")
    }

    /// Probe the mise-managed Elixir for its OTP + Elixir versions.
    pub async fn probe(&self) -> Detected {
        let output = self
            .command()
            .arg("exec")
            .arg("--")
            .arg("elixir")
            .arg("--version")
            .output()
            .await;

        let Ok(output) = output else {
            return Detected::default();
        };
        if !output.status.success() {
            return Detected::default();
        }
        let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
        text.push('\n');
        text.push_str(&String::from_utf8_lossy(&output.stderr));
        Detected {
            otp_major: detect::parse_otp_major(&text),
            elixir: detect::parse_elixir_version(&text),
        }
    }
}

/// A mise release asset matched to the current OS/arch.
struct Asset {
    name: String,
    url: String,
}

/// mise asset os/arch tokens for the current platform.
fn platform_tokens() -> Result<(&'static str, &'static str, &'static str)> {
    let os = if cfg!(target_os = "linux") {
        "linux"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "windows") {
        "windows"
    } else {
        bail!("unsupported operating system for the mise bootstrapper");
    };

    let arch = match std::env::consts::ARCH {
        "x86_64" => "x64",
        "aarch64" => "arm64",
        other => bail!("unsupported CPU architecture for the mise bootstrapper: {other}"),
    };

    let ext = if cfg!(windows) { "zip" } else { "tar.gz" };
    Ok((os, arch, ext))
}

/// Query the GitHub API for the latest mise release and pick the asset matching
/// this platform.
async fn resolve_latest_asset(sink: &LogSink) -> Result<Asset> {
    let (os, arch, ext) = platform_tokens()?;
    log(sink, "Resolving the latest mise release…");

    let client = http_client()?;
    let release: serde_json::Value = client
        .get("https://api.github.com/repos/jdx/mise/releases/latest")
        .header(reqwest::header::ACCEPT, "application/vnd.github+json")
        .send()
        .await
        .context("querying the mise release feed")?
        .error_for_status()
        .context("the mise release feed returned an error status")?
        .json()
        .await
        .context("parsing the mise release feed")?;

    let assets = release
        .get("assets")
        .and_then(|a| a.as_array())
        .ok_or_else(|| anyhow!("mise release feed had no assets"))?;

    // Match e.g. `mise-v2024.12.5-macos-arm64.tar.gz`.
    let suffix = format!("{os}-{arch}.{ext}");
    for asset in assets {
        let name = asset.get("name").and_then(|n| n.as_str()).unwrap_or("");
        if name.ends_with(&suffix) {
            let url = asset
                .get("browser_download_url")
                .and_then(|u| u.as_str())
                .ok_or_else(|| anyhow!("mise asset {name} had no download URL"))?;
            return Ok(Asset {
                name: name.to_string(),
                url: url.to_string(),
            });
        }
    }

    bail!("no mise release asset found for {os}-{arch} ({ext})")
}

fn http_client() -> Result<reqwest::Client> {
    reqwest::Client::builder()
        .user_agent(concat!("hermes-host/", env!("CARGO_PKG_VERSION")))
        .build()
        .context("building HTTP client")
}

async fn download(url: &str) -> Result<Vec<u8>> {
    let client = http_client()?;
    let bytes = client
        .get(url)
        .send()
        .await
        .with_context(|| format!("downloading {url}"))?
        .error_for_status()
        .with_context(|| format!("download of {url} returned an error status"))?
        .bytes()
        .await
        .with_context(|| format!("reading download body from {url}"))?;
    Ok(bytes.to_vec())
}

/// Extract the `mise` binary out of a release archive into `dest`.
fn extract_mise(asset_name: &str, bytes: &[u8], dest: &Path) -> Result<()> {
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating {}", parent.display()))?;
    }

    let bin_filename = dest
        .file_name()
        .and_then(|f| f.to_str())
        .unwrap_or("mise");

    if asset_name.ends_with(".zip") {
        extract_mise_zip(bytes, bin_filename, dest)?;
    } else {
        extract_mise_targz(bytes, bin_filename, dest)?;
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(dest)?.permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(dest, perms)?;
    }

    Ok(())
}

fn extract_mise_targz(bytes: &[u8], bin_filename: &str, dest: &Path) -> Result<()> {
    let decoder = flate2::read::GzDecoder::new(bytes);
    let mut archive = tar::Archive::new(decoder);
    for entry in archive.entries().context("reading mise tarball")? {
        let mut entry = entry?;
        let path = entry.path()?.into_owned();
        if path.file_name().and_then(|n| n.to_str()) == Some(bin_filename)
            || path.file_name().and_then(|n| n.to_str()) == Some("mise")
        {
            let mut out =
                std::fs::File::create(dest).with_context(|| format!("creating {}", dest.display()))?;
            std::io::copy(&mut entry, &mut out).context("writing mise binary")?;
            return Ok(());
        }
    }
    bail!("mise binary not found inside the downloaded tarball")
}

#[cfg(windows)]
fn extract_mise_zip(bytes: &[u8], bin_filename: &str, dest: &Path) -> Result<()> {
    let reader = std::io::Cursor::new(bytes);
    let mut zip = zip::ZipArchive::new(reader).context("reading mise zip")?;
    for i in 0..zip.len() {
        let mut file = zip.by_index(i)?;
        let name = file.name().rsplit('/').next().unwrap_or("");
        if name == bin_filename || name == "mise.exe" {
            let mut out =
                std::fs::File::create(dest).with_context(|| format!("creating {}", dest.display()))?;
            std::io::copy(&mut file, &mut out).context("writing mise binary")?;
            return Ok(());
        }
    }
    bail!("mise binary not found inside the downloaded zip")
}

#[cfg(not(windows))]
fn extract_mise_zip(_bytes: &[u8], _bin_filename: &str, _dest: &Path) -> Result<()> {
    bail!("zip archives are only handled on Windows")
}

/// Run a command, streaming each stdout/stderr line to the log sink, and fail
/// if it exits non-zero.
async fn run_streaming(mut cmd: Command, sink: &LogSink) -> Result<()> {
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn().context("spawning mise")?;

    let mut tasks = Vec::new();
    if let Some(stdout) = child.stdout.take() {
        tasks.push(pump(stdout, sink.clone()));
    }
    if let Some(stderr) = child.stderr.take() {
        tasks.push(pump(stderr, sink.clone()));
    }
    for t in tasks {
        let _ = t.await;
    }

    let status = child.wait().await.context("waiting on mise")?;
    if !status.success() {
        bail!("mise exited with status {status}");
    }
    Ok(())
}

fn pump<R>(reader: R, sink: LogSink) -> tokio::task::JoinHandle<()>
where
    R: tokio::io::AsyncRead + Unpin + Send + 'static,
{
    tokio::spawn(async move {
        let mut lines = BufReader::new(reader).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            log(&sink, line);
        }
    })
}
