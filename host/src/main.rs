use anyhow::Result;
use clap::Parser;
use hermes_host::beam::BeamProcess;
use hermes_host::cli::{Cli, Command};
use hermes_host::tui;
use rand::Rng;

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
        Command::Chat => chat(cli.model, cli.provider).await,
        Command::Gateway => {
            println!("hermes v{}", env!("CARGO_PKG_VERSION"));
            println!("gateway mode on port {}", cli.port);
            println!("model: {}", cli.model);
            println!("provider: {}", cli.provider);
            Ok(())
        }
        Command::Version => {
            println!("hermes {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
    }
}

async fn chat(model: String, provider: String) -> Result<()> {
    let cache_dir = BeamProcess::extract().await?;
    let port = random_port();
    let mut beam = BeamProcess::spawn(&cache_dir, port).await?;
    beam.wait_for_port().await?;

    let client = hermes_host::ws_client::ChannelsClient::connect(port).await?;

    tui::run(client, model, provider).await?;

    beam.shutdown().await?;
    Ok(())
}

fn random_port() -> u16 {
    let mut rng = rand::thread_rng();
    rng.gen_range(10000..=60000)
}
