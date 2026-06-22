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
/// A pending tool-approval request broadcast by the gateway.
#[derive(Debug, Clone)]
pub struct ApprovalRequest {
    pub approval_id: String,
    pub tool_name: String,
    pub args: String,
    pub reason: String,
}

/// A pending clarification request broadcast by the turn loop.
#[derive(Debug, Clone)]
pub struct ClarifyRequest {
    pub question: String,
    pub choices: Vec<String>,
}

/// Which kind of selection an open [`Picker`] is making.
#[derive(Debug, Clone, PartialEq)]
pub enum PickerKind {
    Provider,
    Model,
}

/// A single selectable row in a [`Picker`].
#[derive(Debug, Clone, PartialEq)]
pub struct PickerItem {
    /// Human-readable label shown in the list.
    pub label: String,
    /// The value submitted when the item is confirmed (model id / provider name).
    pub value: String,
}

/// An interactive selection overlay shown in place of the input box.
///
/// Modeled on the `pending_approval` flow: while a picker is open, key presses
/// are routed to picker navigation and normal input is blocked.
#[derive(Debug, Clone)]
pub struct Picker {
    pub title: String,
    pub items: Vec<PickerItem>,
    pub selected: usize,
    pub kind: PickerKind,
}

impl Picker {
    fn move_up(&mut self) {
        if self.selected > 0 {
            self.selected -= 1;
        }
    }

    fn move_down(&mut self) {
        if self.selected + 1 < self.items.len() {
            self.selected += 1;
        }
    }

    fn selected_item(&self) -> Option<&PickerItem> {
        self.items.get(self.selected)
    }
}

/// High-level command produced by a key press.  The TUI loop translates these
/// into outbound Phoenix Channel events.
#[derive(Debug, PartialEq)]
pub enum AppCommand {
    /// Nothing to do.
    None,
    /// Exit the application.
    Exit,
    /// Send a normal user prompt to the session.
    SendPrompt { text: String },
    /// Respond to a pending approval request.
    ApprovalRespond { approval_id: String, approved: bool },
    /// Request the list of active sessions.
    SendSessionList,
    /// Reconfigure the current session with a new model.
    SendSessionConfig { model: String },
    /// Request the list of configured providers (opens a picker on reply).
    SendProviderList,
    /// Add a new provider.
    SendProviderAdd {
        name: String,
        base_url: String,
        api_key: Option<String>,
    },
    /// Remove a provider by name.
    SendProviderRemove { name: String },
    /// Request the list of models for a provider (opens a picker on reply).
    SendModelList { provider: String },
    /// Add a model to a provider's catalog.
    SendModelAdd {
        provider: String,
        model_id: String,
        context_window: Option<u64>,
    },
    /// Switch the current session to a provider (confirmed via picker).
    SetProvider { provider: String },
    /// Switch the current session to a model (confirmed via picker).
    SetModel { model: String },
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
    /// Pending tool approval request, if any. Blocks normal input.
    pub pending_approval: Option<ApprovalRequest>,
    /// Pending clarification request, if any.
    pub pending_clarify: Option<ClarifyRequest>,
    /// Active selection overlay, if any. Blocks normal input.
    pub picker: Option<Picker>,
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
            pending_approval: None,
            pending_clarify: None,
            picker: None,
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
            "approval:request" => self.handle_approval_request(msg),
            "clarify:request" => self.handle_clarify_request(msg),
            "session:status" => self.handle_session_status(msg),
            "providers:listed" => self.handle_providers_listed(msg),
            "models:listed" => self.handle_models_listed(msg),
            "sessions:listed" => self.handle_sessions_listed(msg),
            "session:config" => self.handle_session_config(msg),
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

    fn handle_providers_listed(&mut self, msg: &Message) {
        let providers = match msg.payload.get("providers").and_then(|v| v.as_array()) {
            Some(arr) => arr,
            None => return,
        };
        let items: Vec<PickerItem> = providers
            .iter()
            .filter_map(|p| {
                let name = p.get("name").and_then(|v| v.as_str())?;
                let label = p
                    .get("label")
                    .and_then(|v| v.as_str())
                    .unwrap_or(name)
                    .to_string();
                let mut display = label;
                if p.get("is_default").and_then(|v| v.as_bool()) == Some(true) {
                    display.push_str(" (default)");
                }
                Some(PickerItem {
                    label: display,
                    value: name.to_string(),
                })
            })
            .collect();

        if items.is_empty() {
            self.add_system_message("No providers configured.");
            return;
        }

        let selected = items
            .iter()
            .position(|i| i.value == self.provider)
            .unwrap_or(0);
        self.picker = Some(Picker {
            title: "Select provider".to_string(),
            items,
            selected,
            kind: PickerKind::Provider,
        });
    }

    fn handle_models_listed(&mut self, msg: &Message) {
        let models = match msg.payload.get("models").and_then(|v| v.as_array()) {
            Some(arr) => arr,
            None => return,
        };
        let provider = msg
            .payload
            .get("provider")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let items: Vec<PickerItem> = models
            .iter()
            .filter_map(|m| {
                let model_id = m.get("model_id").and_then(|v| v.as_str())?;
                let label = m
                    .get("label")
                    .and_then(|v| v.as_str())
                    .unwrap_or(model_id)
                    .to_string();
                let mut display = label;
                if let Some(ctx) = m.get("context_window").and_then(|v| v.as_u64()) {
                    display.push_str(&format!(" [{}]", ctx));
                }
                if m.get("is_default").and_then(|v| v.as_bool()) == Some(true) {
                    display.push_str(" (default)");
                }
                Some(PickerItem {
                    label: display,
                    value: model_id.to_string(),
                })
            })
            .collect();

        if items.is_empty() {
            self.add_system_message(&format!("No models available for provider {}.", provider));
            return;
        }

        let selected = items
            .iter()
            .position(|i| i.value == self.model)
            .unwrap_or(0);
        let title = if provider.is_empty() {
            "Select model".to_string()
        } else {
            format!("Select model ({})", provider)
        };
        self.picker = Some(Picker {
            title,
            items,
            selected,
            kind: PickerKind::Model,
        });
    }

    fn handle_sessions_listed(&mut self, msg: &Message) {
        let sessions = match msg.payload.get("sessions").and_then(|v| v.as_array()) {
            Some(arr) => arr,
            None => return,
        };
        if sessions.is_empty() {
            self.add_system_message("No active sessions.");
            return;
        }
        let mut lines = String::from("Active sessions:");
        for s in sessions {
            let id = s.get("id").and_then(|v| v.as_str()).unwrap_or("?");
            let model = s.get("model").and_then(|v| v.as_str()).unwrap_or("?");
            let status = s.get("status").and_then(|v| v.as_str()).unwrap_or("?");
            let count = s
                .get("message_count")
                .and_then(|v| v.as_u64())
                .unwrap_or(0);
            lines.push_str(&format!(
                "\n  {} | {} | {} | {} msgs",
                id, model, status, count
            ));
        }
        self.add_system_message(&lines);
    }

    fn handle_session_config(&mut self, msg: &Message) {
        let mut changed = false;
        if let Some(model) = msg.payload.get("model").and_then(|v| v.as_str()) {
            self.model = model.to_string();
            changed = true;
        }
        if let Some(provider) = msg.payload.get("provider").and_then(|v| v.as_str()) {
            self.provider = provider.to_string();
            changed = true;
        }
        if changed {
            self.add_system_message(&format!(
                "Session updated: model {} | provider {}",
                self.model, self.provider
            ));
        }
    }

    fn handle_approval_request(&mut self, msg: &Message) {
        let approval_id = msg
            .payload
            .get("approval_id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let tool_name = msg
            .payload
            .get("tool_name")
            .and_then(|v| v.as_str())
            .or_else(|| {
                msg.payload
                    .get("details")
                    .and_then(|v| v.get("tool"))
                    .and_then(|v| v.as_str())
            })
            .unwrap_or("action")
            .to_string();
        let args = msg
            .payload
            .get("args")
            .and_then(|v| v.as_str())
            .or_else(|| {
                msg.payload
                    .get("details")
                    .and_then(|v| v.get("args"))
                    .and_then(|v| v.as_str())
            })
            .unwrap_or("")
            .to_string();
        let reason = msg
            .payload
            .get("reason")
            .and_then(|v| v.as_str())
            .or_else(|| {
                msg.payload
                    .get("details")
                    .and_then(|v| v.get("reason"))
                    .and_then(|v| v.as_str())
            })
            .unwrap_or("")
            .to_string();

        self.pending_approval = Some(ApprovalRequest {
            approval_id: approval_id.clone(),
            tool_name: tool_name.clone(),
            args: args.clone(),
            reason: reason.clone(),
        });
        self.status = AppStatus::WaitingForApproval;
        self.add_system_message(&format!(
            "Approval required: {} {}\nReason: {}\nApprove? [Y]es / [N]o",
            tool_name, args, reason
        ));
        self.scroll_to_bottom();
    }

    fn handle_clarify_request(&mut self, msg: &Message) {
        let question = msg
            .payload
            .get("question")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let choices: Vec<String> = msg
            .payload
            .get("choices")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(|s| s.to_string()))
                    .collect()
            })
            .unwrap_or_default();

        self.pending_clarify = Some(ClarifyRequest {
            question: question.clone(),
            choices: choices.clone(),
        });
        let choices_text = if choices.is_empty() {
            "(type your answer)".to_string()
        } else {
            choices.join(", ")
        };
        self.add_system_message(&format!(
            "Clarification needed: {}\nChoices: {}",
            question, choices_text
        ));
        self.scroll_to_bottom();
    }

    /// Handle a crossterm key event and return a high-level command.
    pub fn handle_key_event(&mut self, key: KeyEvent) -> AppCommand {
        if key.kind != KeyEventKind::Press && key.kind != KeyEventKind::Repeat {
            return AppCommand::None;
        }

        // Ctrl-C always exits, even with an overlay open.
        if let KeyCode::Char('c') = key.code {
            if key.modifiers.contains(KeyModifiers::CONTROL) {
                return AppCommand::Exit;
            }
        }

        // While a picker is open, route navigation keys to it and block input.
        if self.picker.is_some() {
            return self.handle_picker_key(key);
        }

        match key.code {
            KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => AppCommand::Exit,
            KeyCode::Esc => {
                if let Some(ref req) = self.pending_approval {
                    return AppCommand::ApprovalRespond {
                        approval_id: req.approval_id.clone(),
                        approved: false,
                    };
                }
                AppCommand::Exit
            }
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
                if !self.is_input_blocked() {
                    let _ = self.input.pop();
                }
                AppCommand::None
            }
            KeyCode::Char(c) => {
                if self.status == AppStatus::WaitingForApproval {
                    let lower = c.to_ascii_lowercase();
                    if let Some(ref req) = self.pending_approval {
                        if lower == 'y' || lower == 'n' {
                            return AppCommand::ApprovalRespond {
                                approval_id: req.approval_id.clone(),
                                approved: lower == 'y',
                            };
                        }
                    }
                    return AppCommand::None;
                }
                self.input.push(c);
                self.history_index = None;
                AppCommand::None
            }
            _ => AppCommand::None,
        }
    }

    fn handle_enter(&mut self) -> AppCommand {
        if let Some(ref req) = self.pending_approval {
            // While waiting for approval, Enter defaults to approve.
            let approved = !self.input.eq_ignore_ascii_case("n");
            return AppCommand::ApprovalRespond {
                approval_id: req.approval_id.clone(),
                approved,
            };
        }

        if self.input.is_empty() {
            return AppCommand::None;
        }

        let text = self.input.clone();
        self.input.clear();
        self.history_index = None;

        if text.starts_with('/') {
            self.dispatch_slash_command(&text)
        } else {
            self.input_history.push(text.clone());
            AppCommand::SendPrompt { text }
        }
    }

    /// Handle a key press while a [`Picker`] overlay is open.
    fn handle_picker_key(&mut self, key: KeyEvent) -> AppCommand {
        match key.code {
            KeyCode::Up => {
                if let Some(picker) = self.picker.as_mut() {
                    picker.move_up();
                }
                AppCommand::None
            }
            KeyCode::Down => {
                if let Some(picker) = self.picker.as_mut() {
                    picker.move_down();
                }
                AppCommand::None
            }
            KeyCode::Esc => {
                self.picker = None;
                AppCommand::None
            }
            KeyCode::Enter => {
                let Some(picker) = self.picker.take() else {
                    return AppCommand::None;
                };
                match picker.selected_item() {
                    Some(item) => {
                        let value = item.value.clone();
                        match picker.kind {
                            PickerKind::Provider => {
                                self.provider = value.clone();
                                AppCommand::SetProvider { provider: value }
                            }
                            PickerKind::Model => {
                                self.model = value.clone();
                                AppCommand::SetModel { model: value }
                            }
                        }
                    }
                    None => AppCommand::None,
                }
            }
            _ => AppCommand::None,
        }
    }

    fn dispatch_slash_command(&mut self, command: &str) -> AppCommand {
        let parts: Vec<&str> = command.split_whitespace().collect();
        if parts.is_empty() {
            return AppCommand::None;
        }

        match parts[0] {
            "/help" => {
                self.show_help();
                AppCommand::None
            }
            "/clear" => {
                self.messages.clear();
                AppCommand::None
            }
            "/status" => {
                self.show_status();
                AppCommand::None
            }
            "/sessions" => AppCommand::SendSessionList,
            "/providers" => self.dispatch_providers_command(&parts),
            "/model" => self.dispatch_model_command(&parts),
            _ => {
                self.add_system_message(&format!("Unknown command: {}", command));
                AppCommand::None
            }
        }
    }

    /// Handle the `/providers` family of subcommands.
    fn dispatch_providers_command(&mut self, parts: &[&str]) -> AppCommand {
        match parts.get(1).copied() {
            None => AppCommand::SendProviderList,
            Some("add") => {
                // /providers add <name> <base_url> [api_key]
                if parts.len() < 4 {
                    self.add_system_message("Usage: /providers add <name> <base_url> [api_key]");
                    return AppCommand::None;
                }
                AppCommand::SendProviderAdd {
                    name: parts[2].to_string(),
                    base_url: parts[3].to_string(),
                    api_key: parts.get(4).map(|s| s.to_string()),
                }
            }
            Some("remove") => {
                if parts.len() < 3 {
                    self.add_system_message("Usage: /providers remove <name>");
                    return AppCommand::None;
                }
                AppCommand::SendProviderRemove {
                    name: parts[2].to_string(),
                }
            }
            Some(other) => {
                self.add_system_message(&format!("Unknown /providers subcommand: {}", other));
                AppCommand::None
            }
        }
    }

    /// Handle the `/model` family of subcommands.
    fn dispatch_model_command(&mut self, parts: &[&str]) -> AppCommand {
        match parts.get(1).copied() {
            // /model (no arg) -> open a model picker for the current provider.
            None => AppCommand::SendModelList {
                provider: self.provider.clone(),
            },
            Some("list") => {
                // /model list [provider]
                let provider = parts
                    .get(2)
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| self.provider.clone());
                AppCommand::SendModelList { provider }
            }
            Some("add") => {
                // /model add <id> [context_window]
                if parts.len() < 3 {
                    self.add_system_message("Usage: /model add <id> [context_window]");
                    return AppCommand::None;
                }
                let context_window = parts.get(3).and_then(|s| s.parse::<u64>().ok());
                AppCommand::SendModelAdd {
                    provider: self.provider.clone(),
                    model_id: parts[2].to_string(),
                    context_window,
                }
            }
            // /model <id> -> switch the live session to that model.
            Some(model_id) => {
                let model = model_id.to_string();
                self.model = model.clone();
                AppCommand::SendSessionConfig { model }
            }
        }
    }

    fn show_help(&mut self) {
        self.add_system_message(
            "Available commands:\n\
             /help     - show this help\n\
             /sessions - list active sessions\n\
             /clear    - clear message history\n\
             /status   - show session status\n\
             /model               - pick a model (interactive)\n\
             /model <id>          - switch model\n\
             /model list [provider] - list models\n\
             /model add <id> [ctx]  - add a model to the catalog\n\
             /providers           - pick a provider (interactive)\n\
             /providers add <name> <base_url> [api_key] - add a provider\n\
             /providers remove <name>                    - remove a provider",
        );
    }

    fn show_status(&mut self) {
        let session = self.session_id.as_deref().unwrap_or("none");
        self.add_system_message(&format!(
            "Status: {} | Session: {} | Model: {} | Provider: {}",
            self.status.as_str(),
            session,
            self.model,
            self.provider
        ));
    }

    fn is_input_blocked(&self) -> bool {
        self.status == AppStatus::WaitingForApproval || self.picker.is_some()
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
    async fn slash_command_help_sessions_and_model() {
        let mut app = app();
        app.status = AppStatus::Connected;

        app.input = "/help".to_string();
        let cmd = app.handle_key_event(KeyEvent::from(KeyCode::Enter));
        assert_eq!(cmd, AppCommand::None);
        assert!(app
            .messages
            .last()
            .unwrap()
            .content
            .contains("Available commands"));

        app.input = "/sessions".to_string();
        let cmd = app.handle_key_event(KeyEvent::from(KeyCode::Enter));
        assert_eq!(cmd, AppCommand::SendSessionList);

        app.input = "/model gpt-5".to_string();
        let cmd = app.handle_key_event(KeyEvent::from(KeyCode::Enter));
        assert_eq!(
            cmd,
            AppCommand::SendSessionConfig {
                model: "gpt-5".to_string()
            }
        );
        assert_eq!(app.model, "gpt-5");
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

    #[tokio::test]
    async fn slash_providers_opens_list_and_model_picker() {
        let mut app = app();
        app.status = AppStatus::Connected;

        app.input = "/providers".to_string();
        let cmd = app.handle_key_event(KeyEvent::from(KeyCode::Enter));
        assert_eq!(cmd, AppCommand::SendProviderList);

        app.input = "/model".to_string();
        let cmd = app.handle_key_event(KeyEvent::from(KeyCode::Enter));
        assert_eq!(
            cmd,
            AppCommand::SendModelList {
                provider: "anthropic".to_string()
            }
        );
    }

    #[tokio::test]
    async fn slash_providers_add_and_remove() {
        let mut app = app();
        app.input = "/providers add local http://localhost:11434 secret".to_string();
        let cmd = app.handle_key_event(KeyEvent::from(KeyCode::Enter));
        assert_eq!(
            cmd,
            AppCommand::SendProviderAdd {
                name: "local".to_string(),
                base_url: "http://localhost:11434".to_string(),
                api_key: Some("secret".to_string()),
            }
        );

        app.input = "/providers remove local".to_string();
        let cmd = app.handle_key_event(KeyEvent::from(KeyCode::Enter));
        assert_eq!(
            cmd,
            AppCommand::SendProviderRemove {
                name: "local".to_string()
            }
        );
    }

    #[test]
    fn providers_listed_populates_picker() {
        let mut app = app();
        app.handle_ws_message(&Message {
            topic: "session:new".to_string(),
            event: "providers:listed".to_string(),
            join_ref: None,
            reference: None,
            payload: json!({
                "providers": [
                    {"name": "anthropic", "label": "Anthropic", "is_default": true},
                    {"name": "local", "label": "Local"}
                ]
            }),
        });
        let picker = app.picker.as_ref().expect("picker should be set");
        assert_eq!(picker.kind, PickerKind::Provider);
        assert_eq!(picker.items.len(), 2);
        // The current provider ("anthropic") should be pre-selected.
        assert_eq!(picker.selected, 0);
        assert_eq!(picker.items[0].value, "anthropic");
    }

    #[test]
    fn picker_navigation_and_confirm_sets_provider() {
        let mut app = app();
        app.handle_ws_message(&Message {
            topic: "session:new".to_string(),
            event: "providers:listed".to_string(),
            join_ref: None,
            reference: None,
            payload: json!({
                "providers": [
                    {"name": "anthropic", "label": "Anthropic"},
                    {"name": "local", "label": "Local"}
                ]
            }),
        });
        // Move down to the second item, then confirm.
        app.handle_key_event(KeyEvent::from(KeyCode::Down));
        let cmd = app.handle_key_event(KeyEvent::from(KeyCode::Enter));
        assert_eq!(
            cmd,
            AppCommand::SetProvider {
                provider: "local".to_string()
            }
        );
        assert_eq!(app.provider, "local");
        assert!(app.picker.is_none(), "picker should close on confirm");
    }

    #[test]
    fn picker_esc_cancels_without_command() {
        let mut app = app();
        app.handle_ws_message(&Message {
            topic: "session:new".to_string(),
            event: "models:listed".to_string(),
            join_ref: None,
            reference: None,
            payload: json!({
                "provider": "anthropic",
                "models": [{"model_id": "claude-opus-4", "label": "Opus"}]
            }),
        });
        assert!(app.picker.is_some());
        let cmd = app.handle_key_event(KeyEvent::from(KeyCode::Esc));
        assert_eq!(cmd, AppCommand::None);
        assert!(app.picker.is_none());
    }

    #[test]
    fn session_config_inbound_updates_status_bar() {
        let mut app = app();
        app.handle_ws_message(&Message {
            topic: "session:new".to_string(),
            event: "session:config".to_string(),
            join_ref: None,
            reference: None,
            payload: json!({"model": "gpt-5", "provider": "local"}),
        });
        assert_eq!(app.model, "gpt-5");
        assert_eq!(app.provider, "local");
    }

    #[test]
    fn picker_blocks_normal_typing() {
        let mut app = app();
        app.picker = Some(Picker {
            title: "Select provider".to_string(),
            items: vec![PickerItem {
                label: "Anthropic".to_string(),
                value: "anthropic".to_string(),
            }],
            selected: 0,
            kind: PickerKind::Provider,
        });
        app.handle_key_event(KeyEvent::from(KeyCode::Char('x')));
        assert!(app.input.is_empty(), "typing must be blocked while picker open");
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
