//! A self-contained ratatui "first run" setup screen.
//!
//! It reports what runtime was detected, asks the user whether to install the
//! missing pieces, and — if they accept — streams mise's install progress in a
//! live log pane. Visually consistent with the chat TUI (bordered panes, status
//! line, keyboard hints).

use super::detect::Detected;
use super::mise::Mise;
use anyhow::Result;
use crossterm::{
    event::{self, Event, KeyCode, KeyEventKind, KeyModifiers},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Gauge, Paragraph},
    Frame, Terminal,
};
use std::io::{self, Stdout};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

/// What the user decided / what happened at the setup screen.
#[derive(Debug)]
pub enum SetupOutcome {
    /// Runtime installed successfully; the app can use the mise-managed Elixir.
    Installed,
    /// User declined the install; caller should fall back to the embedded release.
    Declined,
    /// Install was attempted but failed; caller should fall back, with a reason.
    Failed(String),
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum Phase {
    Prompt,
    Installing,
    Succeeded,
    Failed,
}

const SPINNER: [&str; 8] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧"];

/// RAII guard that restores the terminal on drop, even on panic.
struct TerminalGuard;

impl TerminalGuard {
    fn enter() -> Result<Self> {
        enable_raw_mode()?;
        execute!(io::stdout(), EnterAlternateScreen)?;
        Ok(TerminalGuard)
    }
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
        let _ = execute!(io::stdout(), LeaveAlternateScreen);
    }
}

/// Run the setup screen to completion and return the user's outcome.
pub async fn run_setup(detected: Detected, mise: Mise) -> Result<SetupOutcome> {
    let _guard = TerminalGuard::enter()?;
    let backend = CrosstermBackend::new(io::stdout());
    let mut terminal: Terminal<CrosstermBackend<Stdout>> = Terminal::new(backend)?;

    let shortfalls = detected.shortfalls();
    let mut phase = Phase::Prompt;
    let mut logs: Vec<String> = Vec::new();
    let mut spinner = 0usize;
    let mut error: Option<String> = None;

    // Channels wired up once the install starts.
    let (log_tx, mut log_rx) = mpsc::unbounded_channel::<String>();
    let mut done_rx: Option<oneshot::Receiver<Result<(), String>>> = None;

    loop {
        terminal.draw(|f| draw(f, phase, &detected, &shortfalls, &logs, spinner, error.as_deref()))?;

        // Tick.
        tokio::time::sleep(Duration::from_millis(100)).await;
        spinner = (spinner + 1) % SPINNER.len();

        // Drain any streamed install output.
        while let Ok(line) = log_rx.try_recv() {
            logs.push(line);
            // Keep memory bounded; the pane only shows the tail anyway.
            if logs.len() > 5000 {
                logs.drain(0..1000);
            }
        }

        // Check whether the install task finished.
        if let Some(rx) = done_rx.as_mut() {
            match rx.try_recv() {
                Ok(Ok(())) => {
                    phase = Phase::Succeeded;
                    done_rx = None;
                }
                Ok(Err(msg)) => {
                    error = Some(msg);
                    phase = Phase::Failed;
                    done_rx = None;
                }
                Err(oneshot::error::TryRecvError::Empty) => {}
                Err(oneshot::error::TryRecvError::Closed) => {
                    error = Some("install task ended unexpectedly".to_string());
                    phase = Phase::Failed;
                    done_rx = None;
                }
            }
        }

        // Handle input (non-blocking).
        if event::poll(Duration::from_millis(0))? {
            if let Event::Key(key) = event::read()? {
                if key.kind != KeyEventKind::Press {
                    continue;
                }
                let ctrl_c = key.code == KeyCode::Char('c')
                    && key.modifiers.contains(KeyModifiers::CONTROL);

                match phase {
                    Phase::Prompt => match key.code {
                        KeyCode::Char('i') | KeyCode::Char('y') | KeyCode::Enter => {
                            phase = Phase::Installing;
                            let (tx, rx) = oneshot::channel();
                            done_rx = Some(rx);
                            let sink = log_tx.clone();
                            let mise = mise.clone();
                            tokio::spawn(async move {
                                let result = async {
                                    mise.ensure_installed(&sink).await?;
                                    mise.install_runtime(&sink).await?;
                                    Ok::<(), anyhow::Error>(())
                                }
                                .await;
                                let _ = tx.send(result.map_err(|e| format!("{e:#}")));
                            });
                        }
                        KeyCode::Char('q') | KeyCode::Char('n') | KeyCode::Esc => {
                            return Ok(SetupOutcome::Declined);
                        }
                        _ if ctrl_c => return Ok(SetupOutcome::Declined),
                        _ => {}
                    },
                    // During the install, only Ctrl+C aborts the UI (the spawned
                    // mise task is detached; the caller falls back to embedded).
                    Phase::Installing => {
                        if ctrl_c {
                            return Ok(SetupOutcome::Failed("installation cancelled".into()));
                        }
                    }
                    Phase::Succeeded => return Ok(SetupOutcome::Installed),
                    Phase::Failed => {
                        return Ok(SetupOutcome::Failed(
                            error.unwrap_or_else(|| "installation failed".into()),
                        ))
                    }
                }
            }
        }
    }
}

fn draw(
    f: &mut Frame,
    phase: Phase,
    detected: &Detected,
    shortfalls: &[String],
    logs: &[String],
    spinner: usize,
    error: Option<&str>,
) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(2), // title
            Constraint::Length(6), // status panel
            Constraint::Min(3),    // body (prompt or log)
            Constraint::Length(1), // hint line
        ])
        .split(f.area());

    // Title.
    f.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                "  Hermes Setup",
                Style::default()
                    .fg(Color::Cyan)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                "  —  one-time runtime install",
                Style::default().fg(Color::DarkGray),
            ),
        ])),
        chunks[0],
    );

    // Runtime status panel.
    let panel = Block::default().borders(Borders::ALL).title(" Runtime ");
    let inner = panel.inner(chunks[1]);
    f.render_widget(panel, chunks[1]);
    f.render_widget(Paragraph::new(status_lines(detected)), inner);

    // Body.
    match phase {
        Phase::Prompt => {
            let mut lines = vec![Line::from("")];
            for s in shortfalls {
                lines.push(Line::from(vec![
                    Span::styled("  • ", Style::default().fg(Color::Yellow)),
                    Span::raw(s.clone()),
                ]));
            }
            lines.push(Line::from(""));
            lines.push(Line::from(Span::styled(
                "  Hermes can install a private copy of Erlang/OTP and Elixir",
                Style::default().fg(Color::Gray),
            )));
            lines.push(Line::from(Span::styled(
                "  under ~/.hermes (no admin rights, nothing system-wide).",
                Style::default().fg(Color::Gray),
            )));
            f.render_widget(
                Paragraph::new(lines).block(Block::default().borders(Borders::ALL).title(" Install? ")),
                chunks[2],
            );
        }
        Phase::Installing | Phase::Succeeded | Phase::Failed => {
            let body = Layout::default()
                .direction(Direction::Vertical)
                .constraints([Constraint::Length(3), Constraint::Min(0)])
                .split(chunks[2]);

            // Progress gauge / status row.
            let (ratio, label, color) = match phase {
                Phase::Installing => (
                    0.5,
                    format!("{} installing Erlang/OTP + Elixir…", SPINNER[spinner]),
                    Color::Cyan,
                ),
                Phase::Succeeded => (1.0, "✓ runtime ready".to_string(), Color::Green),
                Phase::Failed => (
                    1.0,
                    format!("✗ {}", error.unwrap_or("install failed")),
                    Color::Red,
                ),
                Phase::Prompt => unreachable!(),
            };
            f.render_widget(
                Gauge::default()
                    .block(Block::default().borders(Borders::ALL).title(" Progress "))
                    .gauge_style(Style::default().fg(color))
                    .ratio(ratio)
                    .label(label),
                body[0],
            );

            // Log tail.
            let log_panel = Block::default().borders(Borders::ALL).title(" Log ");
            let log_inner = log_panel.inner(body[1]);
            f.render_widget(log_panel, body[1]);
            let visible = log_inner.height as usize;
            let start = logs.len().saturating_sub(visible);
            let text: Vec<Line> = logs[start..]
                .iter()
                .map(|l| Line::from(Span::styled(l.clone(), Style::default().fg(Color::Gray))))
                .collect();
            f.render_widget(Paragraph::new(text), log_inner);
        }
    }

    // Hint line.
    let hint = match phase {
        Phase::Prompt => "  [i] install   [q] skip (use bundled runtime)",
        Phase::Installing => "  installing…   [Ctrl+C] cancel",
        Phase::Succeeded => "  press any key to continue",
        Phase::Failed => "  press any key to continue with the bundled runtime",
    };
    f.render_widget(
        Paragraph::new(Span::styled(hint, Style::default().fg(Color::DarkGray))),
        chunks[3],
    );
}

fn status_lines(detected: &Detected) -> Vec<Line<'static>> {
    let ok = Style::default().fg(Color::Green);
    let bad = Style::default().fg(Color::Red);

    let otp = match detected.otp_major {
        Some(v) => Line::from(vec![
            Span::styled("  ✓ ", ok),
            Span::raw(format!("Erlang/OTP {v}")),
        ]),
        None => Line::from(vec![
            Span::styled("  ✗ ", bad),
            Span::raw("Erlang/OTP — not found"),
        ]),
    };
    let elixir = match detected.elixir {
        Some(v) => Line::from(vec![
            Span::styled("  ✓ ", ok),
            Span::raw(format!("Elixir {v}")),
        ]),
        None => Line::from(vec![
            Span::styled("  ✗ ", bad),
            Span::raw("Elixir — not found"),
        ]),
    };
    vec![Line::from(""), otp, elixir]
}
