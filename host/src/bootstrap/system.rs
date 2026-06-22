//! Using a system / mise-managed Elixir: locating the app's mix project,
//! pulling its dependencies from Hex, and running the Phoenix server from
//! source under the chosen runtime.

use super::mise::Mise;
use anyhow::{anyhow, bail, Context, Result};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::net::TcpStream;
use tokio::process::{Child, Command};
use tokio::time::{sleep, timeout};

/// Everything needed to launch the BEAM from a source checkout under a chosen
/// runtime. `mise` is `None` when the runtime is the user's own `PATH` install.
#[derive(Debug, Clone)]
pub struct SystemLaunch {
    pub mise: Option<Mise>,
    pub app_src: PathBuf,
}

/// Locate the Hermes mix project (the directory containing `mix.exs`).
///
/// Resolution order:
/// 1. `HERMES_APP_SRC` environment variable, if set and valid.
/// 2. An ancestor of the running executable that contains the project.
/// 3. An ancestor of the current working directory that contains the project.
///
/// Returns `None` in a packaged binary with no source tree present — in that
/// case the app code travels inside the embedded release instead.
pub fn find_app_source() -> Option<PathBuf> {
    if let Ok(dir) = std::env::var("HERMES_APP_SRC") {
        let path = PathBuf::from(dir);
        if path.join("mix.exs").exists() {
            return Some(path);
        }
    }

    let mut roots = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        roots.push(exe);
    }
    if let Ok(cwd) = std::env::current_dir() {
        roots.push(cwd);
    }

    for root in roots {
        let mut cur: Option<&Path> = Some(root.as_path());
        while let Some(dir) = cur {
            if is_hermes_project(dir) {
                return Some(dir.to_path_buf());
            }
            cur = dir.parent();
        }
    }

    // 4. Extracted embedded app source cache (~/.hermes/app-src/<version>/).
    if let Some(cache_dir) = extracted_app_source() {
        return Some(cache_dir);
    }
    None
}

/// Check the extracted embedded app source cache dir.
fn extracted_app_source() -> Option<PathBuf> {
    let home = super::hermes_home();
    let cache_dir = home.join("app-src").join(crate::app_source::SOURCE_VERSION);
    let marker = cache_dir.join(".hermes-app-source-extracted");
    if marker.exists() && cache_dir.join("mix.exs").exists() {
        Some(cache_dir)
    } else {
        None
    }
}

/// True when `dir/mix.exs` exists and names the `:hermes` app.
fn is_hermes_project(dir: &Path) -> bool {
    let mix = dir.join("mix.exs");
    match std::fs::read_to_string(&mix) {
        Ok(contents) => contents.contains("app: :hermes"),
        Err(_) => false,
    }
}

/// Build a `mix` command, routed through mise when a managed runtime is given,
/// or resolved from `PATH` otherwise.
fn mix_command(mise: Option<&Mise>) -> Command {
    match mise {
        Some(m) => {
            let mut cmd = m.exec();
            cmd.arg("mix");
            cmd
        }
        None => Command::new("mix"),
    }
}

/// Install Hex + rebar locally, fetch all dependencies from Hex, and bring the
/// database up to date.
///
/// We deliberately do *not* run `mix setup`, because its `ecto.setup` step also
/// runs `priv/repo/seeds.exs` — re-seeding on every launch. Instead we run an
/// idempotent `deps.get` → `ecto.create` → `ecto.migrate`. stdio is inherited so
/// the user sees progress directly. Runs in `app_src`.
pub async fn prepare_source(mise: Option<&Mise>, app_src: &Path) -> Result<()> {
    run_inherited(mix_command(mise), &["local.hex", "--force"], app_src)
        .await
        .context("installing Hex")?;
    run_inherited(mix_command(mise), &["local.rebar", "--force"], app_src)
        .await
        .context("installing rebar")?;
    run_inherited(mix_command(mise), &["deps.get"], app_src)
        .await
        .context("fetching dependencies from Hex")?;
    // `ecto.create` is a no-op (and exits 0) when the database already exists.
    run_inherited(mix_command(mise), &["ecto.create", "--quiet"], app_src)
        .await
        .context("creating the database")?;
    run_inherited(mix_command(mise), &["ecto.migrate"], app_src)
        .await
        .context("running migrations")?;
    Ok(())
}

async fn run_inherited(mut cmd: Command, args: &[&str], cwd: &Path) -> Result<()> {
    let status = cmd
        .args(args)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .await
        .context("spawning mix")?;
    if !status.success() {
        bail!("mix {} exited with status {status}", args.join(" "));
    }
    Ok(())
}

/// A Phoenix server (`mix phx.server`) running from source under a chosen
/// runtime. Mirrors the lifecycle of [`crate::beam::BeamProcess`] closely enough
/// to be supervised the same way.
pub struct SystemBeam {
    child: Child,
    port: u16,
    shutdown_done: bool,
}

impl SystemBeam {
    /// Spawn `mix phx.server` from the source tree on `port`.
    pub async fn spawn(launch: &SystemLaunch, port: u16) -> Result<SystemBeam> {
        let mut cmd = mix_command(launch.mise.as_ref());
        cmd.arg("phx.server")
            .current_dir(&launch.app_src)
            .env("PHX_SERVER", "true")
            .env("PORT", port.to_string())
            .kill_on_drop(true);

        // Expose the sidecar binary path the same way the embedded launcher does.
        if let Some(sidecar) = std::env::current_exe()
            .ok()
            .and_then(|exe| exe.parent().map(|p| p.to_path_buf()))
            .map(|dir| dir.join("hermes-sidecar"))
            .filter(|p| p.exists())
        {
            cmd.env("HERMES_SIDECAR_PATH", sidecar);
        }

        let child = cmd
            .spawn()
            .with_context(|| format!("spawning `mix phx.server` in {}", launch.app_src.display()))?;

        Ok(SystemBeam {
            child,
            port,
            shutdown_done: false,
        })
    }

    /// TCP-poll until the server accepts connections. Allows a generous window
    /// because the first run compiles the project.
    pub async fn wait_for_port(&self) -> Result<()> {
        let addr = format!("127.0.0.1:{}", self.port);
        let deadline = Duration::from_secs(180);
        let interval = Duration::from_millis(200);
        let start = tokio::time::Instant::now();
        loop {
            if TcpStream::connect(&addr).await.is_ok() {
                return Ok(());
            }
            if start.elapsed() >= deadline {
                return Err(anyhow!("timed out waiting for {addr}"));
            }
            sleep(interval).await;
        }
    }

    /// OS PID of the server child, if available.
    pub fn pid(&self) -> Option<u32> {
        self.child.id()
    }

    /// Port the server is listening on.
    pub fn port(&self) -> u16 {
        self.port
    }

    /// SIGTERM the process tree, then SIGKILL as a fallback.
    pub async fn graceful_shutdown(&mut self) -> Result<()> {
        if self.shutdown_done {
            return Ok(());
        }
        self.shutdown_done = true;

        if let Some(pid) = self.child.id() {
            let _ = crate::beam::kill_tree(pid, "TERM");
        }
        if let Ok(Ok(_)) = timeout(Duration::from_secs(5), self.child.wait()).await {
            self.verify_no_orphans();
            return Ok(());
        }

        if let Some(pid) = self.child.id() {
            let _ = crate::beam::kill_tree(pid, "KILL");
        }
        let _ = self.child.kill().await;
        let _ = timeout(Duration::from_secs(5), self.child.wait()).await;
        self.verify_no_orphans();
        Ok(())
    }

    fn verify_no_orphans(&self) {
        if let Some(pid) = self.child.id() {
            if crate::beam::tree_alive(pid) {
                tracing::warn!(pid, "system BEAM tree still alive after shutdown; SIGKILL sweep");
                let _ = crate::beam::kill_tree(pid, "KILL");
            }
        }
    }
}
