use std::future::Future;

use hermes_host::app::{App, AppCommand, AppStatus, Client};
use hermes_host::ws_client::Message;
use ratatui::backend::TestBackend;
use ratatui::Terminal;
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
    App::new(
        MockClient { sent: Vec::new() },
        "claude-sonnet-4-20250514",
        "anthropic",
    )
}

#[test]
fn state_transitions_disconnected_to_connected_to_running() {
    let mut app = app();
    assert_eq!(app.status, AppStatus::Disconnected);

    // Simulate the server's session:create reply.
    app.handle_ws_message(&Message {
        topic: "session:new".to_string(),
        event: "phx_reply".to_string(),
        join_ref: None,
        reference: Some("1".to_string()),
        payload: json!({
            "status": "ok",
            "response": { "session_id": "s1", "pid": "<0.1.0>" }
        }),
    });
    assert_eq!(app.status, AppStatus::Connected);
    assert_eq!(app.session_id, Some("s1".to_string()));

    // User submits a prompt.
    app.add_user_message("hello");
    app.status = AppStatus::Running;
    assert_eq!(app.status, AppStatus::Running);

    // Turn completes.
    app.handle_ws_message(&Message {
        topic: "session:new".to_string(),
        event: "turn:complete".to_string(),
        join_ref: None,
        reference: None,
        payload: json!({ "final_response": "Done." }),
    });
    assert_eq!(app.status, AppStatus::Connected);
}

#[test]
fn message_history_rendering_smoke() {
    let backend = TestBackend::new(40, 12);
    let mut terminal = Terminal::new(backend).unwrap();
    let mut app = app();
    app.status = AppStatus::Connected;
    app.session_id = Some("s1".to_string());
    app.add_user_message("hi");

    terminal
        .draw(|frame| hermes_host::tui::render_app(frame, &app))
        .unwrap();
    let buf = terminal.backend().buffer().clone();
    let text: String = buf.content.iter().map(|c| c.symbol().to_string()).collect();
    assert!(text.contains("Messages"));
    assert!(text.contains("Input"));
    assert!(text.contains("status:"));
}

#[test]
fn input_handling_enter_slash_and_history() {
    use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

    let mut app = app();
    app.status = AppStatus::Connected;

    app.input = "/help".to_string();
    let cmd = app.handle_key_event(KeyEvent {
        code: KeyCode::Enter,
        modifiers: KeyModifiers::empty(),
        kind: KeyEventKind::Press,
        state: crossterm::event::KeyEventState::empty(),
    });
    assert_eq!(cmd, AppCommand::None);
    assert!(app
        .messages
        .last()
        .unwrap()
        .content
        .contains("Available commands"));
    assert!(app.input.is_empty());

    app.input = "hello".to_string();
    let cmd = app.handle_key_event(KeyEvent::from(KeyCode::Enter));
    assert_eq!(
        cmd,
        AppCommand::SendPrompt {
            text: "hello".to_string()
        }
    );
    assert_eq!(app.input_history, vec!["hello"]);

    // Up recalls the last sent message.
    let cmd = app.handle_key_event(KeyEvent::from(KeyCode::Up));
    assert_eq!(cmd, AppCommand::None);
    assert_eq!(app.input, "hello");
}

#[test]
fn mock_websocket_event_processing() {
    let mut app = app();
    assert!(app.messages.is_empty());

    app.handle_ws_message(&Message {
        topic: "session:new".to_string(),
        event: "stream:delta".to_string(),
        join_ref: None,
        reference: None,
        payload: json!({ "text": "First " }),
    });
    app.handle_ws_message(&Message {
        topic: "session:new".to_string(),
        event: "stream:delta".to_string(),
        join_ref: None,
        reference: None,
        payload: json!({ "text": "chunk." }),
    });
    app.handle_ws_message(&Message {
        topic: "session:new".to_string(),
        event: "tool:start".to_string(),
        join_ref: None,
        reference: None,
        payload: json!({ "name": "terminal", "args_text": "ls", "tool_id": "t1" }),
    });
    app.handle_ws_message(&Message {
        topic: "session:new".to_string(),
        event: "tool:result".to_string(),
        join_ref: None,
        reference: None,
        payload: json!({ "result": "ok", "tool_id": "t1" }),
    });
    app.handle_ws_message(&Message {
        topic: "session:new".to_string(),
        event: "turn:complete".to_string(),
        join_ref: None,
        reference: None,
        payload: json!({ "final_response": "Done." }),
    });

    assert_eq!(app.messages.len(), 3);
    assert_eq!(app.messages[0].role, "assistant");
    assert_eq!(app.messages[0].content, "First chunk.");
    assert_eq!(app.messages[1].role, "tool");
    assert!(app.messages[1].content.contains("ok"));
    assert_eq!(app.status, AppStatus::Connected);
}
