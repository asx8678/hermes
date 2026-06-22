use clap::Parser;
use hermes_host::cli::{Cli, Command};

fn main() {
    let cli = Cli::parse();

    match cli.command.unwrap_or(Command::Chat) {
        Command::Chat => {
            println!("hermes v{}", env!("CARGO_PKG_VERSION"));
            println!("model: {}", cli.model);
            println!("provider: {}", cli.provider);
            println!("port: {}", cli.port);
        }
        Command::Gateway => {
            println!("hermes v{}", env!("CARGO_PKG_VERSION"));
            println!("gateway mode on port {}", cli.port);
            println!("model: {}", cli.model);
            println!("provider: {}", cli.provider);
        }
        Command::Version => {
            println!("hermes {}", env!("CARGO_PKG_VERSION"));
        }
    }
}
