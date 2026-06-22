use crate::app::{role_label, role_style, App, AppCommand, AppStatus, ApprovalRequest, Client};
use crate::ws_client::ChannelsClient;
use anyhow::{anyhow, Result};
use crossterm::{
    event::{self, Event},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span, Text},
    widgets::{Block, Borders, Paragraph},
    Frame, Terminal,
};
use serde_json::json;
use std::io::{self, Stdout};
use std::time::Duration;
use textwrap::Options as TextWrapOptions;

/// Phoenix topic used for the fresh-session handshake.  The server keeps the
/// channel on this topic after `session:create` returns the real session id.
const NEW_SESSION_TOPIC: &str = "session:new";

/// Render the full TUI frame from the current application state.
///
/// Layout mirrors the Python TUI: a scrollable message history, an input box at
/// the bottom, and a status bar.
pub fn render_app(frame: &mut Frame, app: &App<impl Client>) {
    let area = frame.area();
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Min(0),
            Constraint::Length(3),
            Constraint::Length(1),
        ])
        .split(area);

    render_messages(frame, app, chunks[0]);
    render_input(frame, app, chunks[1]);
    render_status(frame, app, chunks[2]);
}

fn render_messages(frame: &mut Frame, app: &App<impl Client>, area: Rect) {
    let inner = Block::default().borders(Borders::ALL).title("Messages");
    let inner_area = inner.inner(area);
    frame.render_widget(inner, area);

    let width = inner_area.width.max(8) as usize;
    let mut lines: Vec<Line<'static>> = Vec::new();
    for message in &app.messages {
        lines.extend(message_lines(message, width));
    }

    let visible = inner_area.height as usize;
    let max_scroll = lines.len().saturating_sub(visible);
    let scroll = app.scroll.min(max_scroll);
    let text = Text::from(lines);
    let paragraph = Paragraph::new(text).scroll((scroll as u16, 0));
    frame.render_widget(paragraph, inner_area);
}

fn message_lines(message: &crate::app::ChatMessage, width: usize) -> Vec<Line<'static>> {
    let wrap_width = width.saturating_sub(2).max(1);
    let opts = TextWrapOptions::new(wrap_width);
    let mut lines = Vec::new();
    let style = role_style(&message.role);
    let label = role_label(&message.role);

    lines.push(Line::from(vec![
        Span::styled(format!("[{}] ", label), style.add_modifier(Modifier::BOLD)),
        Span::styled(
            message.timestamp.elapsed().as_secs().to_string(),
            Style::default().fg(Color::DarkGray),
        ),
    ]));

    if message.role == "tool" && message.collapsed {
        lines.push(Line::from(Span::styled(
            "  ▶ (collapsed)".to_string(),
            style,
        )));
        return lines;
    }

    for raw_line in message.content.lines() {
        if raw_line.is_empty() {
            lines.push(Line::from(""));
            continue;
        }
        let wrapped = textwrap::fill(raw_line, opts.clone());
        for wrapped_line in wrapped.lines() {
            lines.push(Line::from(vec![
                Span::raw("  "),
                Span::styled(wrapped_line.to_string(), style),
            ]));
        }
    }
    lines
}

fn render_input(frame: &mut Frame, app: &App<impl Client>, area: Rect) {
    if let Some(ref req) = app.pending_approval {
        render_approval_prompt(frame, area, req);
        return;
    }

    let block = Block::default()
        .borders(Borders::ALL)
        .title("Input")
        .border_style(match app.status {
            AppStatus::Running => Style::default().fg(Color::Yellow),
            AppStatus::WaitingForApproval => Style::default().fg(Color::Red),
            _ => Style::default(),
        });
    let text = Text::from(Line::from(vec![
        Span::styled("> ", Style::default().fg(Color::Green)),
        Span::raw(app.input.clone()),
        Span::styled("█", Style::default().fg(Color::Green)),
    ]));
    let paragraph = Paragraph::new(text).block(block);
    frame.render_widget(paragraph, area);
}

fn render_approval_prompt(frame: &mut Frame, area: Rect, req: &ApprovalRequest) {
    let block = Block::default()
        .borders(Borders::ALL)
        .title("Approval Required")
        .border_style(Style::default().fg(Color::Red));
    let text = Text::from(vec![
        Line::from(vec![
            Span::raw("Action: "),
            Span::styled(req.tool_name.clone(), Style::default().fg(Color::Yellow)),
            Span::raw(" "),
            Span::raw(req.args.clone()),
        ]),
        Line::from(vec![Span::raw("Reason: "), Span::raw(req.reason.clone())]),
        Line::from(vec![
            Span::raw("Approve? "),
            Span::styled("[Y]es", Style::default().fg(Color::Green)),
            Span::raw(" / "),
            Span::styled("[N]o", Style::default().fg(Color::Red)),
        ]),
    ]);
    let paragraph = Paragraph::new(text).block(block);
    frame.render_widget(paragraph, area);
}

fn render_status(frame: &mut Frame, app: &App<impl Client>, area: Rect) {
    let status_color = match app.status {
        AppStatus::Connected => Color::Green,
        AppStatus::Running => Color::Yellow,
        AppStatus::WaitingForApproval => Color::Red,
        AppStatus::Disconnected => Color::Gray,
    };
    let session_id = app.session_id.as_deref().unwrap_or("none");
    let status_line = Line::from(vec![
        Span::raw("status: "),
        Span::styled(app.status.as_str(), Style::default().fg(status_color)),
        Span::raw(" | session: "),
        Span::styled(session_id.to_string(), Style::default().fg(Color::Cyan)),
        Span::raw(" | model: "),
        Span::styled(app.model.clone(), Style::default().fg(Color::Magenta)),
        Span::raw(" | provider: "),
        Span::styled(app.provider.clone(), Style::default().fg(Color::Magenta)),
    ]);
    frame.render_widget(Paragraph::new(Text::from(status_line)), area);
}

/// Run the TUI event loop until the user exits.
pub async fn run(mut client: ChannelsClient, model: String, provider: String) -> Result<()> {
    // Create a session before entering the alternate screen so any server-side
    // latency happens before we take over the terminal.
    client.join(NEW_SESSION_TOPIC).await?;
    let session_id = create_session(&mut client, &model, &provider).await?;

    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let mut app = App::new(client, model, provider);
    app.session_id = Some(session_id);
    app.status = AppStatus::Connected;

    let result = run_loop(&mut terminal, &mut app).await;

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    result
}

async fn create_session(
    client: &mut ChannelsClient,
    model: &str,
    provider: &str,
) -> Result<String> {
    client
        .send(
            NEW_SESSION_TOPIC,
            "session:create",
            json!({
                "model": model,
                "provider": provider,
                "api_mode": "streaming"
            }),
        )
        .await?;

    loop {
        let msg = client.recv().await?;
        if msg.topic == NEW_SESSION_TOPIC && msg.event == "phx_reply" {
            let status = msg.payload.get("status").and_then(|v| v.as_str());
            if status != Some("ok") {
                let reason = msg
                    .payload
                    .get("response")
                    .and_then(|v| v.get("reason"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("session:create failed");
                return Err(anyhow!("{}", reason));
            }
            if let Some(sid) = msg
                .payload
                .get("response")
                .and_then(|v| v.get("session_id"))
                .and_then(|v| v.as_str())
            {
                return Ok(sid.to_string());
            }
        }
    }
}

async fn run_loop(
    terminal: &mut Terminal<CrosstermBackend<Stdout>>,
    app: &mut App<ChannelsClient>,
) -> Result<()> {
    let mut tick = tokio::time::interval(Duration::from_millis(50));

    loop {
        terminal.draw(|frame| render_app(frame, app))?;

        tokio::select! {
            _ = tick.tick() => {
                if event::poll(Duration::from_millis(0))? {
                    let ev = event::read()?;
                    if let Event::Key(key) = ev {
                        let cmd = app.handle_key_event(key);
                        match cmd {
                            AppCommand::Exit => break,
                            AppCommand::SendPrompt { text } => {
                                app.add_user_message(&text);
                                app.status = AppStatus::Running;
                                app.ws_client
                                    .send(&app.channel_topic, "send_prompt", json!({"message": text}))
                                    .await?;
                            }
                            AppCommand::ApprovalRespond { approval_id, approved } => {
                                app.pending_approval = None;
                                app.status = AppStatus::Running;
                                app.ws_client
                                    .send(
                                        &app.channel_topic,
                                        "approval:respond",
                                        json!({"approval_id": approval_id, "approved": approved}),
                                    )
                                    .await?;
                            }
                            AppCommand::SendSessionList => {
                                app.ws_client
                                    .send(&app.channel_topic, "session:list", json!({}))
                                    .await?;
                            }
                            AppCommand::SendSessionConfig { model } => {
                                app.ws_client
                                    .send(&app.channel_topic, "session:config", json!({"model": model}))
                                    .await?;
                            }
                            AppCommand::None => {}
                        }
                    }
                }
            }
            msg = app.ws_client.recv() => {
                match msg {
                    Ok(msg) => app.handle_ws_message(&msg),
                    Err(e) => {
                        app.add_system_message(&format!("websocket error: {}", e));
                        break;
                    }
                }
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::backend::TestBackend;
    use serde_json::Value;

    struct MockClient {
        sent: Vec<(String, String, Value)>,
    }

    impl Client for MockClient {
        async fn send(&mut self, _topic: &str, _event: &str, _payload: Value) -> Result<()> {
            Ok(())
        }
    }

    fn test_app() -> App<MockClient> {
        App::new(
            MockClient { sent: Vec::new() },
            "claude-sonnet-4-20250514",
            "anthropic",
        )
    }

    #[test]
    fn renders_message_history_and_status_bar() {
        let backend = TestBackend::new(40, 12);
        let mut terminal = Terminal::new(backend).unwrap();
        let mut app = test_app();
        app.status = AppStatus::Connected;
        app.session_id = Some("abc123".to_string());
        app.messages.push(crate::app::ChatMessage {
            role: "user".to_string(),
            content: "hello".to_string(),
            timestamp: std::time::Instant::now(),
            collapsed: false,
            tool_id: None,
        });
        app.messages.push(crate::app::ChatMessage {
            role: "assistant".to_string(),
            content: "Hi there".to_string(),
            timestamp: std::time::Instant::now(),
            collapsed: false,
            tool_id: None,
        });

        terminal.draw(|frame| render_app(frame, &app)).unwrap();
        let buf = terminal.backend().buffer().clone();

        let text: String = buf.content.iter().map(|c| c.symbol().to_string()).collect();
        assert!(text.contains("Input"), "input box title missing");
        assert!(text.contains("status:"), "status label missing");
        assert!(text.contains("abc123"), "session id missing");
    }

    #[test]
    fn input_box_renders_typed_text() {
        let backend = TestBackend::new(30, 6);
        let mut terminal = Terminal::new(backend).unwrap();
        let mut app = test_app();
        app.input = "typed text".to_string();

        terminal.draw(|frame| render_app(frame, &app)).unwrap();
        let buf = terminal.backend().buffer().clone();

        let text: String = buf.content.iter().map(|c| c.symbol().to_string()).collect();
        assert!(text.contains("typed text"), "input text not rendered");
    }
}
