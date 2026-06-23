use anyhow::{anyhow, Context, Result};
use rand::RngCore;
use std::env;
use std::fs::File;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::net::TcpStream;
use tokio::process::{Child, Command};
use tokio::time::{sleep, timeout};

/// Embedded BEAM release (zstd-compressed).
pub const RELEASE_ZST: &[u8] = include_bytes!("../embedded/hermes-release.tar.zst");

/// Versioned cache dir name inside the cache root.
pub const CACHE_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Manages a spawned BEAM release child process.
pub struct BeamProcess {
    child: Child,
    port: u16,
    cache_dir: PathBuf,
    _db_dir: tempfile::TempDir,
    release_node: String,
    release_cookie: String,
    shutdown_done: bool,
}

impl BeamProcess {
    /// Extract the embedded zstd release to the default versioned cache dir.
    ///
    /// The default cache root is `~/.hermes/cache`. This can be overridden by
    /// setting the `HERMES_CACHE_DIR` environment variable.
    pub async fn extract() -> Result<PathBuf> {
        Self::extract_to(default_cache_root()).await
    }

    /// Extract the embedded zstd release to a versioned dir under `cache_root`.
    ///
    /// The returned path is `cache_root/<cargo-version>/`. It will contain a
    /// `hermes/` release root with `bin/hermes`, `bin/server`, etc.
    pub async fn extract_to(cache_root: impl AsRef<Path>) -> Result<PathBuf> {
        let cache_root = cache_root.as_ref();
        let cache_dir = cache_root.join(CACHE_VERSION);
        let marker = cache_dir.join(".hermes-release-extracted");

        if marker.exists() && cache_dir.join("hermes/bin/hermes").exists() {
            return Ok(cache_dir);
        }

        tokio::fs::create_dir_all(cache_root)
            .await
            .with_context(|| format!("creating cache root {}", cache_root.display()))?;

        let tmp_name = format!(".extract-{}", random_hex(8));
        let tmp_dir = cache_root.join(&tmp_name);

        tokio::task::spawn_blocking({
            let tmp_dir = tmp_dir.clone();
            move || -> Result<()> {
                let _ = std::fs::remove_dir_all(&tmp_dir);
                std::fs::create_dir_all(&tmp_dir)
                    .with_context(|| format!("creating temp extract dir {}", tmp_dir.display()))?;
                let decoder = zstd::Decoder::new(RELEASE_ZST)
                    .context("creating zstd decoder for embedded release")?;
                let mut archive = tar::Archive::new(decoder);
                archive
                    .unpack(&tmp_dir)
                    .with_context(|| format!("unpacking release into {}", tmp_dir.display()))?;
                Ok(())
            }
        })
        .await
        .context("extraction task panicked")??;

        // Remove any partial previously extracted directory before renaming.
        if cache_dir.exists() {
            let _ = tokio::fs::remove_dir_all(&cache_dir).await;
        }

        tokio::fs::rename(&tmp_dir, &cache_dir)
            .await
            .with_context(|| {
                format!("renaming {} to {}", tmp_dir.display(), cache_dir.display())
            })?;

        tokio::fs::write(&marker, b"")
            .await
            .context("writing extraction marker")?;

        Ok(cache_dir)
    }

    /// Spawn the BEAM release from `cache_dir` on the given `port`.
    ///
    /// A temporary database directory is created for this process so concurrent
    /// spawns do not share state. The child is started with `kill_on_drop`.
    ///
    /// When `capture_logs` is set (TUI mode), the child's stdout/stderr are
    /// redirected to `~/.hermes/log/beam.log` so the BEAM's Logger output does
    /// not corrupt the ratatui frame. Headless callers (gateway) pass `false`
    /// and let the BEAM inherit the terminal.
    pub async fn spawn(cache_dir: &Path, port: u16, capture_logs: bool) -> Result<BeamProcess> {
        let release_root = cache_dir.join("hermes");
        let bin = release_root.join("bin/hermes");

        if !bin.exists() {
            return Err(anyhow!(
                "BEAM release binary not found at {}",
                bin.display()
            ));
        }

        let db_dir = tempfile::tempdir().context("creating temporary database directory")?;
        let db_path = db_dir.path().join("hermes.db");
        let secret_key_base = random_hex(32);
        let release_node = format!("hermes-{}", random_hex(6));
        let release_cookie = random_hex(16);

        let mut cmd = Command::new(&bin);
        cmd.arg("start")
            .current_dir(&release_root)
            .env("PHX_SERVER", "true")
            .env("PORT", port.to_string())
            .env("SECRET_KEY_BASE", &secret_key_base)
            .env("DATABASE_PATH", &db_path)
            .env("RELEASE_NODE", &release_node)
            .env("RELEASE_COOKIE", &release_cookie)
            .kill_on_drop(true);

        // In a packaged desktop release the sidecar binary ships next to the host.
        // Expose its path so Elixir sidecar supervisors can find it.
        if let Some(sidecar) = env::current_exe()
            .ok()
            .and_then(|exe| exe.parent().map(|p| p.to_path_buf()))
            .map(|dir| dir.join("hermes-sidecar"))
            .filter(|p| p.exists())
        {
            cmd.env("HERMES_SIDECAR_PATH", sidecar);
        }

        if capture_logs {
            let (out, err) = capture_beam_logs()?;
            cmd.stdin(Stdio::null()).stdout(out).stderr(err);
        }

        let child = cmd
            .spawn()
            .with_context(|| format!("spawning BEAM from {}", bin.display()))?;

        Ok(BeamProcess {
            child,
            port,
            cache_dir: cache_dir.to_path_buf(),
            _db_dir: db_dir,
            release_node,
            release_cookie,
            shutdown_done: false,
        })
    }

    /// TCP poll until `127.0.0.1:<port>` accepts connections.
    ///
    /// Timeouts after 30 seconds and polls every 100 ms.
    pub async fn wait_for_port(&mut self) -> Result<()> {
        let addr = format!("127.0.0.1:{}", self.port);
        let deadline = Duration::from_secs(30);
        let interval = Duration::from_millis(100);

        let start = tokio::time::Instant::now();
        loop {
            match TcpStream::connect(&addr).await {
                Ok(_stream) => {
                    return Ok(());
                }
                Err(_) => {
                    if start.elapsed() >= deadline {
                        return Err(anyhow!("timed out waiting for {}", addr));
                    }
                    sleep(interval).await;
                }
            }
        }
    }

    /// Graceful shutdown of the BEAM child process.
    ///
    /// Attempts, in order:
    /// 1. `bin/hermes stop` RPC shutdown (10 s wait).
    /// 2. SIGTERM to the whole process tree (5 s wait).
    /// 3. SIGKILL fallback to the whole process tree.
    /// 4. Verification that no orphan processes remain.
    pub async fn graceful_shutdown(&mut self) -> Result<()> {
        self.graceful_shutdown_with_timeouts(Duration::from_secs(10), Duration::from_secs(5))
            .await
    }

    /// Graceful shutdown with configurable stage timeouts.
    ///
    /// `stop_wait` is the maximum time to wait after `bin/hermes stop` for the
    /// child to exit on its own. `term_wait` is the maximum time to wait after
    /// SIGTERM before falling back to SIGKILL.
    #[doc(hidden)]
    pub async fn graceful_shutdown_with_timeouts(
        &mut self,
        stop_wait: Duration,
        term_wait: Duration,
    ) -> Result<()> {
        if self.shutdown_done {
            return Ok(());
        }
        self.shutdown_done = true;

        let release_root = self.cache_dir.join("hermes");
        let bin = release_root.join("bin/hermes");

        // 1. Try a graceful RPC stop using the same node/cookie.
        let _ = timeout(Duration::from_secs(10), async {
            Command::new(&bin)
                .arg("stop")
                .current_dir(&release_root)
                .env("RELEASE_ROOT", &release_root)
                .env("RELEASE_NODE", &self.release_node)
                .env("RELEASE_COOKIE", &self.release_cookie)
                .status()
                .await
        })
        .await;

        // 2. Wait up to `stop_wait` for the child to exit on its own.
        if let Ok(Ok(_status)) = timeout(stop_wait, self.child.wait()).await {
            self.verify_no_orphans();
            return Ok(());
        }

        // 3. SIGTERM the whole tree.
        if let Some(pid) = self.child.id() {
            let _ = kill_tree(pid, "TERM");
        }

        if let Ok(Ok(_status)) = timeout(term_wait, self.child.wait()).await {
            self.verify_no_orphans();
            return Ok(());
        }

        // 4. SIGKILL fallback.
        if let Some(pid) = self.child.id() {
            let _ = kill_tree(pid, "KILL");
        }
        let _ = self.child.kill().await;
        let _ = timeout(Duration::from_secs(5), self.child.wait()).await;

        self.verify_no_orphans();
        Ok(())
    }

    /// Backward-compatible alias for [`Self::graceful_shutdown`].
    pub async fn shutdown(&mut self) -> Result<()> {
        self.graceful_shutdown().await
    }

    /// Return the OS PID of the BEAM child, if available.
    pub fn pid(&self) -> Option<u32> {
        self.child.id()
    }

    /// Return true if the child process is still running.
    pub fn is_running(&self) -> bool {
        self.child
            .id()
            .map(|pid| {
                std::process::Command::new("kill")
                    .arg("-0")
                    .arg(pid.to_string())
                    .output()
                    .map(|out| out.status.success())
                    .unwrap_or(false)
            })
            .unwrap_or(false)
    }

    /// Verify no orphan processes remain and log any stragglers.
    fn verify_no_orphans(&self) {
        let Some(pid) = self.child.id() else {
            return;
        };

        if tree_alive(pid) {
            tracing::warn!(
                pid,
                "BEAM process tree still alive after shutdown; attempting final SIGKILL sweep"
            );
            let _ = kill_tree(pid, "KILL");
        }
    }

    /// Port the BEAM process is listening on.
    pub fn port(&self) -> u16 {
        self.port
    }

    /// Path to the extracted cache directory (contains `hermes/`).
    pub fn cache_dir(&self) -> &Path {
        &self.cache_dir
    }
}

/// Collect the immediate child PIDs of `pid` using `pgrep -P`.
#[cfg(unix)]
fn child_pids(pid: u32) -> Vec<u32> {
    let Ok(output) = std::process::Command::new("pgrep")
        .arg("-P")
        .arg(pid.to_string())
        .output()
    else {
        return Vec::new();
    };

    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| line.trim().parse::<u32>().ok())
        .collect()
}

/// Collect `pid` and all descendant PIDs recursively.
#[cfg(unix)]
fn descendant_pids(pid: u32) -> Vec<u32> {
    let mut result = Vec::new();
    let mut stack = vec![pid];

    while let Some(current) = stack.pop() {
        result.push(current);
        for child in child_pids(current) {
            stack.push(child);
        }
    }

    result
}

/// Send `signal` to `pid` and all of its descendants.
#[cfg(unix)]
pub(crate) fn kill_tree(pid: u32, signal: &str) -> Result<()> {
    for target in descendant_pids(pid) {
        let _ = std::process::Command::new("kill")
            .arg(format!("-{}", signal))
            .arg(target.to_string())
            .output();
    }
    Ok(())
}

/// Return true if any process in the tree is still alive.
#[cfg(unix)]
pub(crate) fn tree_alive(pid: u32) -> bool {
    descendant_pids(pid).into_iter().any(|p| {
        std::process::Command::new("kill")
            .arg("-0")
            .arg(p.to_string())
            .output()
            .map(|out| out.status.success())
            .unwrap_or(false)
    })
}

#[cfg(not(unix))]
pub(crate) fn kill_tree(_pid: u32, _signal: &str) -> Result<()> {
    Ok(())
}

#[cfg(not(unix))]
pub(crate) fn tree_alive(_pid: u32) -> bool {
    false
}

/// Build stdout/stderr handles pointing at `~/.hermes/log/beam.log`, truncating
/// it on each launch. Used in TUI mode so the BEAM's Logger output is captured
/// to a file instead of painting over the ratatui frame. The path is announced
/// on stderr before the TUI takes over the screen.
pub fn capture_beam_logs() -> Result<(Stdio, Stdio)> {
    let dir = dirs::home_dir()
        .map(|h| h.join(".hermes/log"))
        .unwrap_or_else(|| {
            std::env::current_dir()
                .expect("current directory")
                .join(".hermes/log")
        });
    std::fs::create_dir_all(&dir)
        .with_context(|| format!("creating beam log dir {}", dir.display()))?;

    let path = dir.join("beam.log");
    let file =
        File::create(&path).with_context(|| format!("creating beam log {}", path.display()))?;
    let err = file.try_clone().context("cloning beam log handle")?;
    eprintln!("hermes: BEAM logs → {}", path.display());

    Ok((Stdio::from(file), Stdio::from(err)))
}

fn default_cache_root() -> PathBuf {
    if let Ok(dir) = std::env::var("HERMES_CACHE_DIR") {
        return PathBuf::from(dir);
    }

    dirs::home_dir()
        .map(|h| h.join(".hermes/cache"))
        .unwrap_or_else(|| {
            std::env::current_dir()
                .expect("current directory")
                .join(".hermes/cache")
        })
}

fn random_hex(byte_len: usize) -> String {
    let mut buf = vec![0u8; byte_len];
    rand::thread_rng().fill_bytes(&mut buf);
    hex::encode(&buf)
}
