use anyhow::Result;
use clap::{Parser, Subcommand};

/// Hermes OS-isolated sidecar binary.
///
/// Each subcommand starts a long-lived sidecar loop that reads JSON-RPC
/// requests from stdin and writes responses to stdout. The BEAM talks to
/// these sidecars via Elixir `Port`s so a crash or runaway command cannot
/// bring down the BEAM.
#[derive(Parser)]
#[command(name = "hermes-sidecar", about = "Hermes OS-isolated sidecar")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Code execution sandbox sidecar loop.
    CodeExecution,
    /// Terminal command sidecar loop.
    Terminal,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Command::CodeExecution => hermes_host::sidecar::code_execution::run().await,
        Command::Terminal => hermes_host::sidecar::terminal::run().await,
    }
}
