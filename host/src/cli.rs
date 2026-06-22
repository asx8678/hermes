use clap::{Parser, Subcommand};

/// Personal AI agent — Rust host CLI.
///
/// Source: 07-rewrite-execution-spec.md (CLI entry + ratatui TUI)
#[derive(Parser)]
#[command(name = "hermes", about = "Personal AI agent", version)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<Command>,

    /// Model identifier to use for the session.
    #[arg(long, default_value = "claude-sonnet-4-20250514")]
    pub model: String,

    /// Provider backend for API calls.
    #[arg(long, default_value = "anthropic")]
    pub provider: String,

    /// Port for gateway / Phoenix Channels websocket.
    #[arg(long, default_value_t = 4000)]
    pub port: u16,
}

#[derive(Subcommand, Debug, PartialEq)]
pub enum Command {
    /// Start TUI (default).
    Chat,
    /// Start gateway mode.
    Gateway,
    /// Print version.
    Version,
}
