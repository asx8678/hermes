//! Render a representative TUI frame to a TestBackend and print it, so the
//! layout/glyphs can be eyeballed without a real terminal.
//!
//! Run: COLORTERM=truecolor cargo run --example tui_snapshot

use anyhow::Result;
use hermes_host::app::{App, AppStatus, ChatMessage, Client};
use hermes_host::tui::render_app;
use ratatui::{backend::TestBackend, Terminal};
use serde_json::Value;
use std::time::Instant;

struct MockClient;

impl Client for MockClient {
    async fn send(&mut self, _topic: &str, _event: &str, _payload: Value) -> Result<()> {
        Ok(())
    }
}

fn msg(role: &str, content: &str) -> ChatMessage {
    ChatMessage {
        role: role.to_string(),
        content: content.to_string(),
        timestamp: Instant::now(),
        collapsed: false,
        tool_id: None,
    }
}

fn main() {
    let (w, h) = (74u16, 22u16);
    let backend = TestBackend::new(w, h);
    let mut terminal = Terminal::new(backend).unwrap();

    let mut app = App::new(MockClient, "moonshotai/Kimi-K2.7-Code", "makora");
    app.status = AppStatus::Connected;
    app.session_id = Some("2F3kP_TlhT9JkJ93saUwCQ".to_string());
    app.input = "explain the supervision tree".to_string();
    app.messages.push(msg("user", "what does this app do?"));
    app.messages.push(msg(
        "assistant",
        "Hermes is a persistent personal AI agent. Each conversation runs in its \
         own GenServer under a supervisor, so a crash in one session is isolated.",
    ));
    app.messages.push(msg("tool", "session_search\nquery: supervision tree"));
    app.messages
        .push(msg("system", "Error during API call: http_error 401"));

    terminal.draw(|f| render_app(f, &app)).unwrap();
    let buf = terminal.backend().buffer().clone();

    println!("┌{}┐", "─".repeat(w as usize));
    for y in 0..h {
        let mut row = String::new();
        for x in 0..w {
            row.push_str(buf[(x, y)].symbol());
        }
        println!("│{row}│");
    }
    println!("└{}┘", "─".repeat(w as usize));
}
