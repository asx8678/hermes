use std::future::Future;

use crossterm::event::{KeyCode, KeyEvent};
use hermes_host::app::{App, AppCommand, AppStatus, Client};
use hermes_host::ws_client::Message;
use serde_json::{json, Value};

struct MockClient {
    sent: Vec<(String, String, Value)>,
}

impl Client for MockClient {
    fn send(
        &mut self,
        topic: &str,
        event: &str,
        payload: Value,
    ) -> impl Future<Output = anyhow::Result<()>> + Send {
        self.sent
            .push((topic.to_string(), event.to_string(), payload));
        async { Ok(()) }
    }
}

fn app() -> App<MockClient> {
    let mut app = App::new(
        MockClient { sent: Vec::new() },
        "claude-sonnet-4-20250514",
        "anthropic",
    );
    app.status = AppStatus::Connected;
    app.session_id = Some("s1".to_string());
    app
}

#[test]
fn approval_request_sets_waiting_for_approval_and_stores_details() {
    let mut app = app();
    app.handle_ws_message(&Message {
        topic: "session:s1".to_string(),
        event: "approval:request".to_string(),
        join_ref: None,
        reference: None,
        payload: json!({
            "approval_id": "a123",
            "tool_name": "terminal",
            "args": "rm -rf /",
            "reason": "destructive command"
        }),
    });

    assert_eq!(app.status, AppStatus::WaitingForApproval);
    let req = app
        .pending_approval
        .as_ref()
        .expect("approval request stored");
    assert_eq!(req.approval_id, "a123");
    assert_eq!(req.tool_name, "terminal");
    assert_eq!(req.args, "rm -rf /");
    assert_eq!(req.reason, "destructive command");

    let last = app.messages.last().unwrap();
    assert!(last.content.contains("Approval required"));
    assert!(last.content.contains("terminal"));
    assert!(last.content.contains("destructive command"));
}

#[test]
fn approval_y_key_sends_approval_response_with_id() {
    let mut app = app();
    app.handle_ws_message(&Message {
        topic: "session:s1".to_string(),
        event: "approval:request".to_string(),
        join_ref: None,
        reference: None,
        payload: json!({"approval_id": "a123", "tool_name": "terminal", "args": "ls"}),
    });

    let cmd = app.handle_key_event(KeyEvent::from(KeyCode::Char('y')));
    assert_eq!(
        cmd,
        AppCommand::ApprovalRespond {
            approval_id: "a123".to_string(),
            approved: true,
        }
    );
}

#[test]
fn approval_esc_key_sends_denial_response_with_id() {
    let mut app = app();
    app.handle_ws_message(&Message {
        topic: "session:s1".to_string(),
        event: "approval:request".to_string(),
        join_ref: None,
        reference: None,
        payload: json!({"approval_id": "a456", "tool_name": "terminal", "args": "ls"}),
    });

    let cmd = app.handle_key_event(KeyEvent::from(KeyCode::Esc));
    assert_eq!(
        cmd,
        AppCommand::ApprovalRespond {
            approval_id: "a456".to_string(),
            approved: false,
        }
    );
}

#[test]
fn approval_enter_defaults_to_approve() {
    let mut app = app();
    app.handle_ws_message(&Message {
        topic: "session:s1".to_string(),
        event: "approval:request".to_string(),
        join_ref: None,
        reference: None,
        payload: json!({"approval_id": "a789", "tool_name": "terminal", "args": "ls"}),
    });

    let cmd = app.handle_key_event(KeyEvent::from(KeyCode::Enter));
    assert_eq!(
        cmd,
        AppCommand::ApprovalRespond {
            approval_id: "a789".to_string(),
            approved: true,
        }
    );
}

#[test]
fn approval_blocks_normal_input() {
    let mut app = app();
    app.handle_ws_message(&Message {
        topic: "session:s1".to_string(),
        event: "approval:request".to_string(),
        join_ref: None,
        reference: None,
        payload: json!({"approval_id": "a000", "tool_name": "terminal", "args": "ls"}),
    });

    app.handle_key_event(KeyEvent::from(KeyCode::Char('x')));
    assert!(app.input.is_empty());

    app.handle_key_event(KeyEvent::from(KeyCode::Backspace));
    assert!(app.input.is_empty());
}

#[test]
fn slash_help_displays_help_text() {
    let mut app = app();
    app.input = "/help".to_string();
    let cmd = app.handle_key_event(KeyEvent::from(KeyCode::Enter));

    assert_eq!(cmd, AppCommand::None);
    let last = app.messages.last().unwrap();
    assert!(last.content.contains("/help"));
    assert!(last.content.contains("/sessions"));
    assert!(last.content.contains("/model"));
    assert!(last.content.contains("/clear"));
    assert!(last.content.contains("/status"));
}

#[test]
fn slash_sessions_requests_session_list() {
    let mut app = app();
    app.input = "/sessions".to_string();
    let cmd = app.handle_key_event(KeyEvent::from(KeyCode::Enter));

    assert_eq!(cmd, AppCommand::SendSessionList);
}

#[test]
fn slash_model_sends_config_change_and_updates_model() {
    let mut app = app();
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

#[test]
fn slash_status_displays_status() {
    let mut app = app();
    app.input = "/status".to_string();
    let cmd = app.handle_key_event(KeyEvent::from(KeyCode::Enter));

    assert_eq!(cmd, AppCommand::None);
    let last = app.messages.last().unwrap();
    assert!(last.content.contains("Status:"));
    assert!(last.content.contains("s1"));
    assert!(last.content.contains("claude-sonnet-4-20250514"));
    assert!(last.content.contains("anthropic"));
}

#[test]
fn slash_clear_clears_messages() {
    let mut app = app();
    app.add_user_message("hello");
    app.input = "/clear".to_string();
    let cmd = app.handle_key_event(KeyEvent::from(KeyCode::Enter));

    assert_eq!(cmd, AppCommand::None);
    assert!(app.messages.is_empty());
}

#[test]
fn non_slash_input_sent_as_prompt() {
    let mut app = app();
    app.input = "hello world".to_string();
    let cmd = app.handle_key_event(KeyEvent::from(KeyCode::Enter));

    assert_eq!(
        cmd,
        AppCommand::SendPrompt {
            text: "hello world".to_string()
        }
    );
    assert_eq!(app.input_history, vec!["hello world"]);
}

#[test]
fn clarify_request_displays_question_and_choices() {
    let mut app = app();
    app.handle_ws_message(&Message {
        topic: "session:s1".to_string(),
        event: "clarify:request".to_string(),
        join_ref: None,
        reference: None,
        payload: json!({
            "question": "Which region?",
            "choices": ["us-east-1", "us-west-2"]
        }),
    });

    let req = app
        .pending_clarify
        .as_ref()
        .expect("clarify request stored");
    assert_eq!(req.question, "Which region?");
    assert_eq!(req.choices, vec!["us-east-1", "us-west-2"]);

    let last = app.messages.last().unwrap();
    assert!(last.content.contains("Which region?"));
    assert!(last.content.contains("us-east-1"));
    assert!(last.content.contains("us-west-2"));
}
