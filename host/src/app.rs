use anyhow::Result;
use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use ratatui::style::{Color, Style};
use serde_json::Value;
use std::time::Instant;

use std::future::Future;

use crate::ws_client::{ChannelsClient, Message};

/// Async send trait abstracting the Phoenix Channels client so `App` can be
/// tested with a mock transport.
pub trait Client: Send {
    fn send(
        &mut self,
        topic: &str,
        event: &str,
        payload: Value,
    ) -> impl Future<Output = Result<()>> + Send;
}

impl Client for ChannelsClient {
    fn send(
        &mut self,
        topic: &str,
        event: &str,
        payload: Value,
    ) -> impl Future<Output = Result<()>> + Send {
        ChannelsClient::send(self, topic, event, payload)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum AppStatus {
    Disconnected,
    Connected,
    Running,
    WaitingForApproval,
}

impl AppStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            AppStatus::Disconnected => "disconnected",
            AppStatus::Connected => "connected",
            AppStatus::Running => "running",
            AppStatus::WaitingForApproval => "approval",
        }
    }
}

#[derive(Debug, Clone)]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
    pub timestamp: Instant,
    /// Tool messages may be collapsed in the UI.
    pub collapsed: bool,
    /// For correlating `tool:result` events with their `tool:start` block.
    pub tool_id: Option<String>,
}

impl ChatMessage {
    fn new(role: impl Into<String>, content: impl Into<String>) -> Self {
        Self {
            role: role.into(),
            content: content.into(),
            timestamp: Instant::now(),
            collapsed: false,
            tool_id: None,
        }
    }
}

/// High-level command produced by a key press.  The TUI loop translates these
/// into outbound Phoenix Channel events.
#[derive(Debug, PartialEq)]
pub enum AppCommand {
    None,
    Exit,
    SendPrompt { text: String },
    SlashExec { command: String },
    ApprovalRespond { choice: String },
}

/// TUI state machine.
///
/// Ports the handler semantics of `tui_gateway/server.py:898` to a Rust
/// ratatui frontend that speaks Phoenix Channels over the local WebSocket.
pub struct App<T: Client> {
    pub ws_client: T,
    pub session_id: Option<String>,
    /// The Phoenix topic this client actually joined on (usually `session:new`
    /// for a fresh chat, or `session:<id>` after a resume).
    pub channel_topic: String,
    pub input: String,
    pub input_history: Vec<String>,
    pub history_index: Option<usize>,
    pub messages: Vec<ChatMessage>,
    pub status: AppStatus,
    /// Scroll offset in wrapped display lines.
    pub scroll: usize,
    pub model: String,
    pub provider: String,
}

impl<T: Client> App<T> {
    pub fn new(ws_client: T, model: impl Into<String>, provider: impl Into<String>) -> Self {
        Self {
            ws_client,
            session_id: None,
            channel_topic: "session:new".to_string(),
            input: String::new(),
            input_history: Vec::new(),
            history_index: None,
            messages: Vec::new(),
            status: AppStatus::Disconnected,
            scroll: 0,
            model: model.into(),
            provider: provider.into(),
        }
    }

    /// Append a user-visible status or error message.
    pub fn add_system_message(&mut self, text: &str) {
        self.messages.push(ChatMessage::new("system", text));
    }

    /// Append a user message to the transcript and scroll to the bottom.
    pub fn add_user_message(&mut self, text: &str) {
        self.messages.push(ChatMessage::new("user", text));
        self.scroll_to_bottom();
    }

    fn scroll_to_bottom(&mut self) {
        // The exact visible height is known only at render time; a large value
        // is clamped by ratatui, so this reliably shows the newest content.
        self.scroll = usize::MAX;
    }

    /// Apply a received Phoenix Channels message to the state machine.
    pub fn handle_ws_message(&mut self, msg: &Message) {
        match msg.event.as_str() {
            "phx_reply" => self.handle_phx_reply(msg),
            "stream:delta" => self.handle_stream_delta(msg),
            "tool:start" => self.handle_tool_start(msg),
            "tool:result" => self.handle_tool_result(msg),
            "turn:complete" => self.handle_turn_complete(msg),
            "turn:error" => self.handle_turn_error(msg),
            "session:status" => self.handle_session_status(msg),
            _ => {}
        }
    }

    fn handle_phx_reply(&mut self, msg: &Message) {
        let status = msg
            .payload
            .get("status")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if status != "ok" {
            let reason = msg
                .payload
                .get("response")
                .and_then(|v| v.get("reason"))
                .and_then(|v| v.as_str())
                .or_else(|| msg.payload.get("reason").and_then(|v| v.as_str()))
                .unwrap_or("channel error");
            self.add_system_message(&format!("channel error: {}", reason));
            return;
        }

        // `session:create` and `session:resume` replies carry the real id.
        if let Some(response) = msg.payload.get("response").and_then(|v| v.as_object()) {
            if let Some(sid) = response.get("session_id").and_then(|v| v.as_str()) {
                self.session_id = Some(sid.to_string());
                self.status = AppStatus::Connected;
                self.scroll_to_bottom();
            }
        }
    }

    fn handle_stream_delta(&mut self, msg: &Message) {
        let text = msg
            .payload
            .get("text")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if text.is_empty() {
            return;
        }
        if self.messages.last().map(|m| m.role.as_str()) != Some("assistant") {
            self.messages.push(ChatMessage::new("assistant", ""));
        }
        if let Some(last) = self.messages.last_mut() {
            last.content.push_str(text);
        }
        self.status = AppStatus::Running;
        self.scroll_to_bottom();
    }

    fn handle_tool_start(&mut self, msg: &Message) {
        let name = msg
            .payload
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("tool");
        let args = msg
            .payload
            .get("args_text")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let tool_id = msg
            .payload
            .get("tool_id")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        let mut m = ChatMessage::new("tool", format!("{} {}", name, args));
        m.tool_id = tool_id;
        self.messages.push(m);
        self.status = AppStatus::Running;
        self.scroll_to_bottom();
    }

    fn handle_tool_result(&mut self, msg: &Message) {
        let result = msg
            .payload
            .get("result")
            .and_then(|v| v.as_str())
            .or_else(|| msg.payload.get("error").and_then(|v| v.as_str()))
            .unwrap_or("(no result)");
        let tool_id = msg.payload.get("tool_id").and_then(|v| v.as_str());

        if let Some(id) = tool_id {
            if let Some(m) = self
                .messages
                .iter_mut()
                .find(|m| m.tool_id.as_deref() == Some(id))
            {
                m.content.push('\n');
                m.content.push_str(result);
                self.scroll_to_bottom();
                return;
            }
        }
        // No matching start block: append a standalone result.
        self.messages
            .push(ChatMessage::new("tool", format!("result: {}", result)));
        self.scroll_to_bottom();
    }

    fn handle_turn_complete(&mut self, msg: &Message) {
        if let Some(text) = msg.payload.get("final_response").and_then(|v| v.as_str()) {
            if text.is_empty() {
                self.status = AppStatus::Connected;
                return;
            }
            if self.messages.last().map(|m| m.role.as_str()) != Some("assistant") {
                self.messages.push(ChatMessage::new("assistant", text));
            } else if let Some(last) = self.messages.last_mut() {
                // If the stream already produced text, keep it; otherwise use
                // the server's final response.
                if last.content.is_empty() {
                    last.content = text.to_string();
                }
            }
        }
        self.status = AppStatus::Connected;
        self.scroll_to_bottom();
    }

    fn handle_turn_error(&mut self, msg: &Message) {
        let err = msg
            .payload
            .get("error")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown turn error");
        self.add_system_message(err);
        self.status = AppStatus::Connected;
    }

    fn handle_session_status(&mut self, msg: &Message) {
        if let Some(status) = msg.payload.get("status").and_then(|v| v.as_str()) {
            match status {
                "running" => self.status = AppStatus::Running,
                "idle" => self.status = AppStatus::Connected,
                "waiting_for_approval" => self.status = AppStatus::WaitingForApproval,
                _ => {}
            }
        }
    }

    /// Handle a crossterm key event and return a high-level command.
    pub fn handle_key_event(&mut self, key: KeyEvent) -> AppCommand {
        if key.kind != KeyEventKind::Press && key.kind != KeyEventKind::Repeat {
            return AppCommand::None;
        }

        match key.code {
            KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => AppCommand::Exit,
            KeyCode::Esc => AppCommand::Exit,
            KeyCode::Enter => self.handle_enter(),
            KeyCode::Up => {
                self.cycle_history(-1);
                AppCommand::None
            }
            KeyCode::Down => {
                self.cycle_history(1);
                AppCommand::None
            }
            KeyCode::Backspace => {
                let _ = self.input.pop();
                AppCommand::None
            }
            KeyCode::Char(c) => {
                self.input.push(c);
                self.history_index = None;
                AppCommand::None
            }
            _ => AppCommand::None,
        }
    }

    fn handle_enter(&mut self) -> AppCommand {
        if self.status == AppStatus::WaitingForApproval {
            // While waiting for approval, Enter sends an allow response.
            let choice = if self.input.eq_ignore_ascii_case("n") {
                "deny"
            } else {
                "allow"
            };
            self.input.clear();
            self.history_index = None;
            return AppCommand::ApprovalRespond {
                choice: choice.to_string(),
            };
        }

        if self.input.is_empty() {
            return AppCommand::None;
        }

        let text = self.input.clone();
        self.input.clear();
        self.history_index = None;
        self.input_history.push(text.clone());

        if text.starts_with('/') {
            AppCommand::SlashExec { command: text }
        } else {
            AppCommand::SendPrompt { text }
        }
    }

    fn cycle_history(&mut self, delta: i8) {
        if self.input_history.is_empty() {
            return;
        }
        match (delta, self.history_index) {
            (-1, None) => {
                self.history_index = Some(self.input_history.len().saturating_sub(1));
            }
            (-1, Some(idx)) if idx > 0 => {
                self.history_index = Some(idx - 1);
            }
            (1, Some(idx)) if idx + 1 < self.input_history.len() => {
                self.history_index = Some(idx + 1);
            }
            (1, Some(_)) | (1, None) => {
                self.history_index = None;
                self.input.clear();
                return;
            }
            _ => {}
        }
        if let Some(idx) = self.history_index {
            self.input = self.input_history[idx].clone();
        }
    }
}

/// Style used for a given role in the message list.
pub fn role_style(role: &str) -> Style {
    let color = match role {
        "user" => Color::Blue,
        "assistant" => Color::Green,
        "tool" => Color::Yellow,
        "system" => Color::Red,
        _ => Color::Gray,
    };
    Style::default().fg(color)
}

pub fn role_label(role: &str) -> &'static str {
    match role {
        "user" => "you",
        "assistant" => "assistant",
        "tool" => "tool",
        "system" => "system",
        _ => "unknown",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    struct MockClient {
        sent: Vec<(String, String, Value)>,
    }

    impl Client for MockClient {
        async fn send(&mut self, topic: &str, event: &str, payload: Value) -> Result<()> {
            self.sent
                .push((topic.to_string(), event.to_string(), payload));
            Ok(())
        }
    }

    fn app() -> App<MockClient> {
        App::new(
            MockClient { sent: Vec::new() },
            "claude-sonnet-4-20250514",
            "anthropic",
        )
    }

    #[test]
    fn status_starts_disconnected() {
        let app = app();
        assert_eq!(app.status, AppStatus::Disconnected);
        assert!(app.session_id.is_none());
    }

    #[test]
    fn session_create_reply_sets_session_id_and_connected() {
        let mut app = app();
        app.handle_ws_message(&Message {
            topic: "session:new".to_string(),
            event: "phx_reply".to_string(),
            join_ref: None,
            reference: Some("1".to_string()),
            payload: json!({
                "status": "ok",
                "response": { "session_id": "abc123", "pid": "<0.123.0>" }
            }),
        });
        assert_eq!(app.session_id, Some("abc123".to_string()));
        assert_eq!(app.status, AppStatus::Connected);
    }

    #[test]
    fn send_prompt_sets_status_running_and_adds_user_message() {
        let mut app = app();
        app.status = AppStatus::Connected;
        app.session_id = Some("abc123".to_string());
        app.add_user_message("hello");
        assert_eq!(app.messages.len(), 1);
        assert_eq!(app.messages[0].role, "user");
        assert_eq!(app.messages[0].content, "hello");
    }

    #[tokio::test]
    async fn enter_sends_prompt_and_updates_state() {
        let mut app = app();
        app.status = AppStatus::Connected;
        app.session_id = Some("abc123".to_string());
        app.input = "hello".to_string();

        let cmd = app.handle_key_event(KeyEvent::from(KeyCode::Enter));
        assert_eq!(
            cmd,
            AppCommand::SendPrompt {
                text: "hello".to_string()
            }
        );
        assert!(app.input.is_empty());
        assert_eq!(app.input_history, vec!["hello"]);
    }

    #[tokio::test]
    async fn slash_command_routes_to_slash_exec() {
        let mut app = app();
        app.status = AppStatus::Connected;
        app.input = "/help".to_string();
        let cmd = app.handle_key_event(KeyEvent::from(KeyCode::Enter));
        assert_eq!(
            cmd,
            AppCommand::SlashExec {
                command: "/help".to_string()
            }
        );
    }

    #[tokio::test]
    async fn ctrl_c_exits() {
        let mut app = app();
        let cmd = app.handle_key_event(KeyEvent {
            code: KeyCode::Char('c'),
            modifiers: KeyModifiers::CONTROL,
            kind: KeyEventKind::Press,
            state: crossterm::event::KeyEventState::empty(),
        });
        assert_eq!(cmd, AppCommand::Exit);
    }

    #[test]
    fn stream_delta_appends_to_assistant_message() {
        let mut app = app();
        app.handle_ws_message(&Message {
            topic: "session:new".to_string(),
            event: "stream:delta".to_string(),
            join_ref: None,
            reference: None,
            payload: json!({ "text": "Hello" }),
        });
        app.handle_ws_message(&Message {
            topic: "session:new".to_string(),
            event: "stream:delta".to_string(),
            join_ref: None,
            reference: None,
            payload: json!({ "text": " world" }),
        });
        assert_eq!(app.messages.len(), 1);
        assert_eq!(app.messages[0].role, "assistant");
        assert_eq!(app.messages[0].content, "Hello world");
        assert_eq!(app.status, AppStatus::Running);
    }

    #[test]
    fn tool_start_and_result_render() {
        let mut app = app();
        app.handle_ws_message(&Message {
            topic: "session:new".to_string(),
            event: "tool:start".to_string(),
            join_ref: None,
            reference: None,
            payload: json!({
                "name": "terminal",
                "args_text": "ls -la",
                "tool_id": "t1"
            }),
        });
        assert_eq!(app.messages[0].role, "tool");
        app.handle_ws_message(&Message {
            topic: "session:new".to_string(),
            event: "tool:result".to_string(),
            join_ref: None,
            reference: None,
            payload: json!({ "result": "ok", "tool_id": "t1" }),
        });
        assert!(app.messages[0].content.contains("ok"));
    }

    #[test]
    fn turn_complete_finishes_turn() {
        let mut app = app();
        app.status = AppStatus::Running;
        app.handle_ws_message(&Message {
            topic: "session:new".to_string(),
            event: "turn:complete".to_string(),
            join_ref: None,
            reference: None,
            payload: json!({ "final_response": "Done." }),
        });
        assert_eq!(app.status, AppStatus::Connected);
        assert_eq!(app.messages[0].content, "Done.");
    }

    #[test]
    fn turn_error_renders_system_message() {
        let mut app = app();
        app.status = AppStatus::Running;
        app.handle_ws_message(&Message {
            topic: "session:new".to_string(),
            event: "turn:error".to_string(),
            join_ref: None,
            reference: None,
            payload: json!({ "error": "session busy" }),
        });
        assert_eq!(app.status, AppStatus::Connected);
        assert_eq!(app.messages[0].role, "system");
        assert_eq!(app.messages[0].content, "session busy");
    }

    #[test]
    fn input_history_cycles_up_and_down() {
        let mut app = app();
        app.input_history = vec!["first".to_string(), "second".to_string()];
        app.cycle_history(-1);
        assert_eq!(app.input, "second");
        app.cycle_history(-1);
        assert_eq!(app.input, "first");
        app.cycle_history(1);
        assert_eq!(app.input, "second");
        app.cycle_history(1);
        assert!(app.input.is_empty());
    }
}
