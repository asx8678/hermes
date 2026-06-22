//! Native runtime bootstrapper.
//!
//! On launch this checks whether a sufficiently recent Erlang/OTP + Elixir is
//! available. If not, it offers (via a ratatui setup screen) to install a
//! private copy under `~/.hermes` using an app-local [`mise`](mise) runtime
//! manager — no shell scripts, no system packages, no `sudo`. Already-installed
//! mise-managed runtimes are kept up to date in the background.
//!
//! The result is reported back to the host, which prefers the system runtime
//! and falls back to the embedded ERTS release when no runtime is available
//! (e.g. the user declined, or the install failed).

pub mod detect;
pub mod mise;
pub mod system;
pub mod ui;

use anyhow::Result;
use detect::Detected;
use mise::Mise;
use std::path::PathBuf;
use system::SystemLaunch;

/// Minimum Erlang/OTP major release the app supports.
pub const MIN_OTP_MAJOR: u32 = 26;
/// Minimum Elixir `(major, minor)` the app supports.
pub const MIN_ELIXIR: (u32, u32) = (1, 15);

/// Which runtime the host should launch the BEAM with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActiveRuntime {
    /// A satisfactory Erlang/Elixir already on the user's `PATH`.
    System,
    /// The app-local, mise-managed runtime under `~/.hermes`.
    MiseManaged,
    /// No system runtime available; use the bundled ERTS release.
    Embedded,
}

/// Outcome of [`ensure_runtime`], including human-readable notes for logging.
///
/// When `launch` is `Some`, the host should try to run the BEAM from source on
/// that runtime, falling back to the embedded release if it fails to come up.
/// When `None`, the host uses the embedded release directly.
#[derive(Debug, Clone)]
pub struct RuntimeReport {
    pub active: ActiveRuntime,
    pub notes: Vec<String>,
    pub launch: Option<SystemLaunch>,
}

impl RuntimeReport {
    fn new(active: ActiveRuntime) -> Self {
        RuntimeReport {
            active,
            notes: Vec::new(),
            launch: None,
        }
    }

    fn note(mut self, msg: impl Into<String>) -> Self {
        self.notes.push(msg.into());
        self
    }
}

/// The Hermes home directory (`~/.hermes`, overridable via `HERMES_HOME`).
pub fn hermes_home() -> PathBuf {
    if let Ok(dir) = std::env::var("HERMES_HOME") {
        return PathBuf::from(dir);
    }
    dirs::home_dir()
        .map(|h| h.join(".hermes"))
        .unwrap_or_else(|| PathBuf::from(".hermes"))
}

/// Ensure a usable Elixir/Erlang runtime, installing one if necessary.
///
/// `interactive` controls whether the ratatui setup screen may be shown. Set it
/// to `false` for headless/server contexts (no controlling terminal), where a
/// missing runtime simply falls back to the embedded release.
pub async fn ensure_runtime(interactive: bool) -> Result<RuntimeReport> {
    let home = hermes_home();
    let mise = Mise::new(&home);

    // 1. A good-enough runtime already on PATH wins — don't touch the user's
    //    own install, just use it (and pull deps from Hex when in a source tree).
    let on_path = detect::detect_on_path().await;
    if on_path.is_satisfactory() {
        let mut notes = vec![describe("system PATH", &on_path)];
        let launch = prepare_launch(None, &mut notes).await;
        return Ok(report(ActiveRuntime::System, notes, launch));
    }

    // 2. A previously mise-managed runtime — reuse it and keep it current.
    if mise.is_installed() {
        let managed = mise.probe().await;
        if managed.is_satisfactory() {
            spawn_background_upgrade(mise.clone());
            let mut notes = vec![
                describe("mise-managed", &managed),
                "checking for runtime updates in the background".to_string(),
            ];
            let launch = prepare_launch(Some(&mise), &mut notes).await;
            return Ok(report(ActiveRuntime::MiseManaged, notes, launch));
        }
    }

    // 3. Nothing usable. In headless mode, fall back silently.
    if !interactive {
        return Ok(RuntimeReport::new(ActiveRuntime::Embedded)
            .note("no system runtime found; using the bundled release (headless mode)"));
    }

    // 4. Offer to install via the setup screen.
    let detected_for_display = best_known(&on_path, &mise).await;
    match ui::run_setup(detected_for_display, mise.clone()).await? {
        ui::SetupOutcome::Installed => {
            let mut notes =
                vec!["installed Erlang/OTP + Elixir via mise under ~/.hermes".to_string()];
            let launch = prepare_launch(Some(&mise), &mut notes).await;
            Ok(report(ActiveRuntime::MiseManaged, notes, launch))
        }
        ui::SetupOutcome::Declined => Ok(RuntimeReport::new(ActiveRuntime::Embedded)
            .note("install declined; using the bundled runtime")),
        ui::SetupOutcome::Failed(reason) => Ok(RuntimeReport::new(ActiveRuntime::Embedded)
            .note(format!("install failed ({reason}); using the bundled runtime"))),
    }
}

fn report(active: ActiveRuntime, notes: Vec<String>, launch: Option<SystemLaunch>) -> RuntimeReport {
    RuntimeReport {
        active,
        notes,
        launch,
    }
}

/// When running from a source checkout, fetch deps from Hex and prepare the DB
/// (`mix setup`), returning a launch spec. A missing source tree (packaged
/// binary) or a failed prepare is non-fatal: the host uses the embedded release.
async fn prepare_launch(mise: Option<&Mise>, notes: &mut Vec<String>) -> Option<SystemLaunch> {
    let Some(app_src) = system::find_app_source() else {
        notes.push("no source checkout found; using the bundled release".to_string());
        return None;
    };
    notes.push(format!("fetching Hex deps from {}", app_src.display()));
    match system::prepare_source(mise, &app_src).await {
        Ok(()) => Some(SystemLaunch {
            mise: mise.cloned(),
            app_src,
        }),
        Err(e) => {
            notes.push(format!("`mix setup` failed ({e:#}); using the bundled release"));
            None
        }
    }
}

/// Kick off `mise upgrade` without blocking startup.
fn spawn_background_upgrade(mise: Mise) {
    tokio::spawn(async move {
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
        // Drain log lines into tracing so they don't accumulate unbounded.
        let drain = tokio::spawn(async move {
            while let Some(line) = rx.recv().await {
                tracing::debug!(target: "mise.upgrade", "{line}");
            }
        });
        if let Err(e) = mise.upgrade(&tx).await {
            tracing::warn!("background runtime upgrade failed: {e:#}");
        }
        drop(tx);
        let _ = drain.await;
    });
}

/// Pick the most informative detection result for the setup screen.
async fn best_known(on_path: &Detected, mise: &Mise) -> Detected {
    if on_path.otp_major.is_some() || on_path.elixir.is_some() {
        return on_path.clone();
    }
    if mise.is_installed() {
        return mise.probe().await;
    }
    on_path.clone()
}

fn describe(source: &str, d: &Detected) -> String {
    let otp = d
        .otp_major
        .map(|v| format!("OTP {v}"))
        .unwrap_or_else(|| "OTP ?".into());
    let elixir = d
        .elixir
        .map(|v| format!("Elixir {v}"))
        .unwrap_or_else(|| "Elixir ?".into());
    format!("using {source} runtime ({otp}, {elixir})")
}
