use anyhow::Result;
use clap::Parser;
use futures_util::future::Future;
use hermes_host::beam::BeamProcess;
use hermes_host::cli::{Cli, Command};
use hermes_host::supervisor::BeamSupervisor;
use hermes_host::tui;
use hermes_host::ws_client::ChannelsClient;
use parking_lot::Mutex;
use rand::Rng;
use std::future::pending;
use std::path::PathBuf;
use std::sync::Arc;

type SharedSupervisor = Arc<Mutex<Option<BeamSupervisor>>>;

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
    let cache_dir = BeamProcess::extract().await?;
    let port = random_port();

    run_supervised(cache_dir, port, async move {
        let client = ChannelsClient::connect(port).await?;
        tui::run(client, model, provider).await
    })
    .await
}

async fn run_gateway(port: u16, model: String, provider: String) -> Result<()> {
    let cache_dir = BeamProcess::extract().await?;

    println!("hermes v{}", env!("CARGO_PKG_VERSION"));
    println!("gateway mode on port {}", port);
    println!("model: {}", model);
    println!("provider: {}", provider);

    // Signal handling is performed by `run_supervised`; this future simply waits
    // until something else (a signal or an error) terminates the process.
    run_supervised(cache_dir, port, pending::<Result<()>>()).await
}

async fn run_supervised<Fut>(cache_dir: PathBuf, port: u16, fut: Fut) -> Result<()>
where
    Fut: Future<Output = Result<()>>,
{
    let supervisor = BeamSupervisor::start(&cache_dir, port).await?;
    let shared: SharedSupervisor = Arc::new(Mutex::new(Some(supervisor)));

    // Synchronous last-resort cleanup if a panic escapes an async task.
    let default_hook = std::panic::take_hook();
    let panic_guard = shared.clone();
    std::panic::set_hook(Box::new(move |info| {
        eprintln!("panic: {}", info);
        if let Some(sup) = panic_guard.lock().as_ref() {
            if let Some(pid) = sup.beam().pid() {
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

async fn graceful_shutdown(shared: SharedSupervisor) -> Result<()> {
    if let Some(mut sup) = shared.lock().take() {
        sup.shutdown().await?;
    }
    Ok(())
}

fn random_port() -> u16 {
    let mut rng = rand::thread_rng();
    rng.gen_range(10000..=60000)
}
