use anyhow::Result;
use clap::Parser;
use futures_util::future::Future;
use hermes_host::beam::BeamProcess;
use hermes_host::bootstrap::system::{SystemBeam, SystemLaunch};
use hermes_host::bootstrap::{self, RuntimeReport};
use hermes_host::cli::{Cli, Command};
use hermes_host::supervisor::BeamSupervisor;
use hermes_host::tui;
use hermes_host::ws_client::ChannelsClient;
use parking_lot::Mutex;
use rand::Rng;
use std::future::pending;
use std::sync::Arc;

/// A running BEAM, either launched from a system/mise-managed runtime (from
/// source) or from the embedded ERTS release.
enum RunningBeam {
    Embedded(BeamSupervisor),
    System(SystemBeam),
}

impl RunningBeam {
    fn pid(&self) -> Option<u32> {
        match self {
            RunningBeam::Embedded(s) => s.beam().pid(),
            RunningBeam::System(b) => b.pid(),
        }
    }

    async fn shutdown(&mut self) -> Result<()> {
        match self {
            RunningBeam::Embedded(s) => s.shutdown().await,
            RunningBeam::System(b) => b.graceful_shutdown().await,
        }
    }
}

type SharedBeam = Arc<Mutex<Option<RunningBeam>>>;

#[tokio::main]
async fn main() {
    if let Err(e) = run().await {
        eprintln!("error: {:#}", e);
        std::process::exit(1);
    }
}

async fn run() -> Result<()> {
    let cli = Cli::parse();

    match cli.command.unwrap_or(Command::Chat) {
        Command::Chat => run_chat(cli.model, cli.provider).await,
        Command::Gateway => run_gateway(cli.port, cli.model, cli.provider).await,
        Command::Version => {
            println!("hermes {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
    }
}

async fn run_chat(model: String, provider: String) -> Result<()> {
    // Ensure a usable Elixir/Erlang runtime (interactive: may show the setup UI).
    let report = bootstrap::ensure_runtime(true).await?;
    print_runtime_notes(&report);

    let port = random_port();
    // TUI mode: capture BEAM logs to a file so they don't corrupt the frame.
    let beam = start_beam(report, port, true).await?;

    run_supervised(beam, async move {
        let client = ChannelsClient::connect(port).await?;
        tui::run(client, model, provider).await
    })
    .await
}

async fn run_gateway(port: u16, model: String, provider: String) -> Result<()> {
    // Headless: never pop a TUI; a missing runtime falls back to the release.
    let report = bootstrap::ensure_runtime(false).await?;
    print_runtime_notes(&report);

    println!("hermes v{}", env!("CARGO_PKG_VERSION"));
    println!("gateway mode on port {}", port);
    println!("model: {}", model);
    println!("provider: {}", provider);

    // Headless gateway: let the BEAM inherit the terminal so logs are visible.
    let beam = start_beam(report, port, false).await?;

    // Signal handling is performed by `run_supervised`; this future simply waits
    // until something else (a signal or an error) terminates the process.
    run_supervised(beam, pending::<Result<()>>()).await
}

/// Resolve the runtime report into a running BEAM. Prefers a system/mise-managed
/// launch from source; on any failure, falls back to the embedded release.
async fn start_beam(report: RuntimeReport, port: u16, capture_logs: bool) -> Result<RunningBeam> {
    if let Some(launch) = report.launch {
        match start_system(&launch, port, capture_logs).await {
            Ok(beam) => return Ok(RunningBeam::System(beam)),
            Err(e) => {
                eprintln!("hermes: system runtime launch failed ({e:#}); using bundled release");
            }
        }
    }

    let cache_dir = BeamProcess::extract().await?;
    let supervisor = BeamSupervisor::start(&cache_dir, port, capture_logs).await?;
    Ok(RunningBeam::Embedded(supervisor))
}

async fn start_system(launch: &SystemLaunch, port: u16, capture_logs: bool) -> Result<SystemBeam> {
    let beam = SystemBeam::spawn(launch, port, capture_logs).await?;
    beam.wait_for_port().await?;
    Ok(beam)
}

fn print_runtime_notes(report: &RuntimeReport) {
    for note in &report.notes {
        eprintln!("hermes: {note}");
    }
}

async fn run_supervised<Fut>(beam: RunningBeam, fut: Fut) -> Result<()>
where
    Fut: Future<Output = Result<()>>,
{
    let shared: SharedBeam = Arc::new(Mutex::new(Some(beam)));

    // Synchronous last-resort cleanup if a panic escapes an async task.
    let default_hook = std::panic::take_hook();
    let panic_guard = shared.clone();
    std::panic::set_hook(Box::new(move |info| {
        eprintln!("panic: {}", info);
        if let Some(beam) = panic_guard.lock().as_ref() {
            if let Some(pid) = beam.pid() {
                let _ = std::process::Command::new("kill")
                    .arg("-KILL")
                    .arg(pid.to_string())
                    .output();
            }
        }
        default_hook(info);
    }));

    let result = select_with_signals(fut).await;
    graceful_shutdown(shared).await?;
    result
}

async fn select_with_signals<Fut>(fut: Fut) -> Result<()>
where
    Fut: Future<Output = Result<()>>,
{
    #[cfg(unix)]
    {
        use tokio::signal::unix::{signal, SignalKind};
        let mut sigint = signal(SignalKind::interrupt())?;
        let mut sigterm = signal(SignalKind::terminate())?;

        tokio::select! {
            res = fut => res,
            _ = sigint.recv() => {
                eprintln!("Received SIGINT, shutting down...");
                Ok(())
            }
            _ = sigterm.recv() => {
                eprintln!("Received SIGTERM, shutting down...");
                Ok(())
            }
        }
    }

    #[cfg(not(unix))]
    {
        let mut ctrl_c = tokio::signal::ctrl_c()?;
        tokio::select! {
            res = fut => res,
            _ = ctrl_c.recv() => {
                eprintln!("Received Ctrl+C, shutting down...");
                Ok(())
            }
        }
    }
}

async fn graceful_shutdown(shared: SharedBeam) -> Result<()> {
    let beam = shared.lock().take();
    if let Some(mut beam) = beam {
        beam.shutdown().await?;
    }
    Ok(())
}

fn random_port() -> u16 {
    let mut rng = rand::thread_rng();
    rng.gen_range(10000..=60000)
}
