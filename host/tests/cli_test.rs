use clap::Parser;
use hermes_host::cli::{Cli, Command};

#[test]
fn parse_chat_with_flags() {
    let cli = Cli::parse_from(["hermes", "--model", "gpt-4", "--port", "8080", "chat"]);
    assert_eq!(cli.model, "gpt-4");
    assert_eq!(cli.port, 8080);
    assert_eq!(cli.provider, "anthropic");
    assert_eq!(cli.command, Some(Command::Chat));
}

#[test]
fn parse_version() {
    let cli = Cli::parse_from(["hermes", "version"]);
    assert_eq!(cli.command, Some(Command::Version));
}

#[test]
fn parse_no_args_defaults_to_chat() {
    let cli = Cli::parse_from(["hermes"]);
    assert_eq!(cli.command, None);
    assert_eq!(cli.model, "claude-sonnet-4-20250514");
    assert_eq!(cli.provider, "anthropic");
    assert_eq!(cli.port, 4000);
}

#[test]
fn parse_gateway() {
    let cli = Cli::parse_from(["hermes", "gateway"]);
    assert_eq!(cli.command, Some(Command::Gateway));
}
