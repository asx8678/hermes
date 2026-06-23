use crate::app::{App, AppCommand, AppStatus, ApprovalRequest, Client, Picker};
use crate::theme::Palette;
use crate::ws_client::ChannelsClient;
use anyhow::{anyhow, Result};
use crossterm::{
    event::{self, Event},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{
    backend::CrosstermBackend,
    layout::{Alignment, Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span, Text},
    widgets::{Block, BorderType, Borders, Paragraph},
    Frame, Terminal,
};
use serde_json::json;
use std::io::{self, Stdout};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use textwrap::Options as TextWrapOptions;

/// Phoenix topic used for the fresh-session handshake.  The server keeps the
/// channel on this topic after `session:create` returns the real session id.
const NEW_SESSION_TOPIC: &str = "session:new";

/// Frame counter used to animate the footer spinner.
static FRAME: AtomicU64 = AtomicU64::new(0);

/// A rounded, accent-titled panel matching droid's boxes.
fn panel(title: &str, edge: Color, p: Palette) -> Block<'static> {
    let mut block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(edge));
    if !title.is_empty() {
        block = block.title(Span::styled(
            title.to_string(),
            Style::default().fg(p.primary).add_modifier(Modifier::BOLD),
        ));
    }
    block
}

/// Render the full TUI frame from the current application state.
///
/// Tokyo Night look ported from droid: a borderless scrolling transcript, a
/// one-line status row, a rounded accent-edged input box, and a footer.
pub fn render_app(frame: &mut Frame, app: &App<impl Client>) {
    let p = Palette::current();
    let area = frame.area();
    // When a picker is open, give the input panel more room for the list.
    let input_height = match &app.picker {
        Some(picker) => {
            // borders (2) + up to ~8 visible items, clamped to the frame.
            let rows = picker.items.len().clamp(1, 8) as u16 + 2;
            rows.min(area.height.saturating_sub(4)).max(3)
        }
        None => 3,
    };
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Min(0),       // transcript (fills)
            Constraint::Length(1),    // status row
            Constraint::Length(input_height), // input
            Constraint::Length(1),    // footer
        ])
        .split(area);

    render_messages(frame, app, chunks[0], p);
    render_status_row(frame, app, chunks[1], p);
    render_input(frame, app, chunks[2], p);
    render_footer(frame, app, chunks[3], p);
}

/// The empty-session splash, centered in the transcript area.
fn welcome_lines(p: Palette) -> Vec<Line<'static>> {
    let accent = Style::default().fg(p.primary).add_modifier(Modifier::BOLD);
    let muted = Style::default().fg(p.muted);
    vec![
        Line::from(""),
        Line::from(Span::styled("hermes", accent)).centered(),
        Line::from(Span::styled("persistent personal AI agent", muted)).centered(),
        Line::from(""),
        Line::from(Span::styled(
            "type a message · /help · Ctrl+C to quit",
            muted,
        ))
        .centered(),
    ]
}

fn render_messages(frame: &mut Frame, app: &App<impl Client>, area: Rect, p: Palette) {
    let width = (area.width.max(8)) as usize;
    let mut lines: Vec<Line<'static>> = Vec::new();
    for (i, message) in app.messages.iter().enumerate() {
        if i > 0 {
            lines.push(Line::from(""));
        }
        lines.extend(message_lines(message, width, p));
    }
    if lines.is_empty() {
        lines = welcome_lines(p);
    }

    let visible = area.height as usize;
    let max_scroll = lines.len().saturating_sub(visible);
    let scroll = app.scroll.min(max_scroll);
    let paragraph = Paragraph::new(Text::from(lines)).scroll((scroll as u16, 0));
    frame.render_widget(paragraph, area);
}

fn message_lines(message: &crate::app::ChatMessage, width: usize, p: Palette) -> Vec<Line<'static>> {
    let wrap_width = width.saturating_sub(2).max(1);
    let opts = TextWrapOptions::new(wrap_width);

    // Collapsed tool output gets a single muted line.
    if message.role == "tool" && message.collapsed {
        return vec![Line::from(Span::styled(
            "  • ▶ (collapsed)".to_string(),
            Style::default().fg(p.tool_param),
        ))];
    }

    let mut lines = Vec::new();
    let mut first = true;
    for raw_line in message.content.lines() {
        if raw_line.is_empty() {
            lines.push(Line::from(""));
            first = false;
            continue;
        }
        for wrapped_line in textwrap::fill(raw_line, opts.clone()).lines() {
            let w = wrapped_line.to_string();
            let line = match message.role.as_str() {
                // User: an accent gutter bar with a subtly tinted background.
                "user" => Line::from(vec![
                    Span::styled("▌ ", Style::default().fg(p.user_symbol)),
                    Span::styled(w, Style::default().fg(p.user_text).bg(p.user_bg)),
                ]),
                // Assistant: indented primary text.
                "assistant" => Line::from(vec![
                    Span::raw("  "),
                    Span::styled(w, Style::default().fg(p.text)),
                ]),
                // Tool: a bullet header on the first line, params after.
                "tool" => {
                    if first {
                        Line::from(vec![
                            Span::styled("  • ".to_string(), Style::default().fg(p.primary)),
                            Span::styled(
                                w,
                                Style::default().fg(p.tool_name).add_modifier(Modifier::BOLD),
                            ),
                        ])
                    } else {
                        Line::from(vec![
                            Span::raw("    "),
                            Span::styled(w, Style::default().fg(p.tool_param)),
                        ])
                    }
                }
                // System messages carry errors/notices — keep them visible.
                "system" => Line::from(vec![
                    Span::raw("  "),
                    Span::styled(w, Style::default().fg(p.error)),
                ]),
                _ => Line::from(vec![
                    Span::raw("  "),
                    Span::styled(w, Style::default().fg(p.muted)),
                ]),
            };
            lines.push(line);
            first = false;
        }
    }
    lines
}

fn render_input(frame: &mut Frame, app: &App<impl Client>, area: Rect, p: Palette) {
    if let Some(ref req) = app.pending_approval {
        render_approval_prompt(frame, area, req, p);
        return;
    }
    if let Some(ref picker) = app.picker {
        render_picker(frame, area, picker, p);
        return;
    }

    // Accent edge by default; warning while a turn runs, error while blocked.
    let edge = match app.status {
        AppStatus::Running => p.warning,
        AppStatus::WaitingForApproval => p.error,
        _ => p.primary,
    };
    let text = Text::from(Line::from(vec![
        Span::styled(
            "> ",
            Style::default().fg(p.user_symbol).add_modifier(Modifier::BOLD),
        ),
        Span::styled(app.input.clone(), Style::default().fg(p.text)),
        Span::styled("█", Style::default().fg(p.user_symbol)),
    ]));
    let paragraph = Paragraph::new(text).block(panel("", edge, p));
    frame.render_widget(paragraph, area);
}

fn render_approval_prompt(frame: &mut Frame, area: Rect, req: &ApprovalRequest, p: Palette) {
    let text = Text::from(vec![
        Line::from(vec![
            Span::styled("Action: ", Style::default().fg(p.muted)),
            Span::styled(
                req.tool_name.clone(),
                Style::default().fg(p.tool_name).add_modifier(Modifier::BOLD),
            ),
            Span::raw(" "),
            Span::styled(req.args.clone(), Style::default().fg(p.tool_param)),
        ]),
        Line::from(vec![
            Span::styled("Reason: ", Style::default().fg(p.muted)),
            Span::styled(req.reason.clone(), Style::default().fg(p.text)),
        ]),
        Line::from(vec![
            Span::styled("Approve? ", Style::default().fg(p.text)),
            Span::styled("[Y]es", Style::default().fg(p.success).add_modifier(Modifier::BOLD)),
            Span::styled(" / ", Style::default().fg(p.muted)),
            Span::styled("[N]o", Style::default().fg(p.error).add_modifier(Modifier::BOLD)),
        ]),
    ]);
    let paragraph = Paragraph::new(text).block(panel(" Approval Required ", p.error, p));
    frame.render_widget(paragraph, area);
}

fn render_picker(frame: &mut Frame, area: Rect, picker: &Picker, p: Palette) {
    let block = panel(
        &format!(" {}  (↑/↓ move · Enter select · Esc cancel) ", picker.title),
        p.primary,
        p,
    );
    let inner = block.inner(area);
    frame.render_widget(block, area);

    // Keep only as many rows as fit and scroll so the selected item stays visible.
    let visible = (inner.height as usize).max(1);
    let start = if picker.selected >= visible {
        picker.selected + 1 - visible
    } else {
        0
    };

    let mut lines: Vec<Line<'static>> = Vec::new();
    for (idx, item) in picker.items.iter().enumerate().skip(start).take(visible) {
        if idx == picker.selected {
            lines.push(Line::from(Span::styled(
                format!(" ❯ {} ", item.label),
                Style::default().fg(p.sel_fg).bg(p.sel_bg).add_modifier(Modifier::BOLD),
            )));
        } else {
            lines.push(Line::from(vec![
                Span::raw("   "),
                Span::styled(item.label.clone(), Style::default().fg(p.text)),
            ]));
        }
    }

    frame.render_widget(Paragraph::new(Text::from(lines)), inner);
}

/// Shorten a model id to its last path segment for the glanceable status row
/// (e.g. `moonshotai/Kimi-K2.7-Code` → `Kimi-K2.7-Code`).
fn short_model(model: &str) -> String {
    model.rsplit('/').next().unwrap_or(model).to_string()
}

/// Status row above the input: connection + session on the left, model + provider on the right.
fn render_status_row(frame: &mut Frame, app: &App<impl Client>, area: Rect, p: Palette) {
    let status_color = match app.status {
        AppStatus::Connected => p.success,
        AppStatus::Running => p.warning,
        AppStatus::WaitingForApproval => p.error,
        AppStatus::Disconnected => p.muted,
    };
    let session_id = app.session_id.as_deref().unwrap_or("none");
    let muted = Style::default().fg(p.muted);

    let left = Line::from(vec![
        Span::styled(
            format!(" {}", app.status.as_str()),
            Style::default().fg(status_color).add_modifier(Modifier::BOLD),
        ),
        Span::styled(format!("  ·  {session_id}"), muted),
    ]);
    let right = Line::from(vec![
        Span::styled(short_model(&app.model), Style::default().fg(p.secondary)),
        Span::styled(format!("  ·  {} ", app.provider), muted),
    ]);
    // Split so the long model/provider on the right can't overwrite the left.
    let halves = Layout::horizontal([Constraint::Percentage(60), Constraint::Percentage(40)])
        .split(area);
    frame.render_widget(Paragraph::new(left), halves[0]);
    frame.render_widget(Paragraph::new(right).alignment(Alignment::Right), halves[1]);
}

/// Footer below the input: key hints, with an animated spinner while a turn runs.
fn render_footer(frame: &mut Frame, app: &App<impl Client>, area: Rect, p: Palette) {
    let muted = Style::default().fg(p.muted);
    let line = match app.status {
        AppStatus::Running => {
            let glyphs = ["●", "◉", "○"];
            let idx = (FRAME.fetch_add(1, Ordering::Relaxed) / 4) as usize % glyphs.len();
            Line::from(vec![
                Span::styled(
                    format!(" {} working…", glyphs[idx]),
                    Style::default().fg(p.primary).add_modifier(Modifier::BOLD),
                ),
                Span::styled("  ·  Ctrl+C quit".to_string(), muted),
            ])
        }
        AppStatus::WaitingForApproval => Line::from(Span::styled(
            " awaiting approval — [Y]es / [N]o".to_string(),
            Style::default().fg(p.warning),
        )),
        _ => Line::from(Span::styled(
            " Enter send · /help · Ctrl+C quit".to_string(),
            muted,
        )),
    };
    frame.render_widget(Paragraph::new(line), area);
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
                            AppCommand::SendProviderList => {
                                app.ws_client
                                    .send(&app.channel_topic, "providers:list", json!({}))
                                    .await?;
                            }
                            AppCommand::SendProviderAdd { name, base_url, api_key } => {
                                let mut payload = json!({
                                    "name": name,
                                    "kind": "openai",
                                    "base_url": base_url,
                                });
                                if let Some(key) = api_key {
                                    payload["api_key"] = json!(key);
                                }
                                app.ws_client
                                    .send(&app.channel_topic, "providers:add", payload)
                                    .await?;
                            }
                            AppCommand::SendProviderRemove { name } => {
                                app.ws_client
                                    .send(&app.channel_topic, "providers:remove", json!({"name": name}))
                                    .await?;
                            }
                            AppCommand::SendModelList { provider } => {
                                app.ws_client
                                    .send(&app.channel_topic, "models:list", json!({"provider": provider}))
                                    .await?;
                            }
                            AppCommand::SendModelAdd { provider, model_id, context_window } => {
                                let mut payload = json!({
                                    "provider_name": provider,
                                    "model_id": model_id,
                                });
                                if let Some(ctx) = context_window {
                                    payload["context_window"] = json!(ctx);
                                }
                                app.ws_client
                                    .send(&app.channel_topic, "models:add", payload)
                                    .await?;
                            }
                            AppCommand::SetProvider { provider } => {
                                app.ws_client
                                    .send(&app.channel_topic, "session:config", json!({"provider": provider}))
                                    .await?;
                            }
                            AppCommand::SetModel { model } => {
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
        assert!(text.contains("connected"), "status word missing");
        assert!(text.contains("abc123"), "session id missing");
        assert!(text.contains("hello"), "user message missing");
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
