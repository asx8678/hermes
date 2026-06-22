use anyhow::{anyhow, Context, Result};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::time::Duration;
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::{interval, MissedTickBehavior};
use tokio_tungstenite::{
    connect_async, tungstenite::protocol::Message as WsMessage, MaybeTlsStream, WebSocketStream,
};

/// A single Phoenix Channels message.
#[derive(Debug, Clone)]
pub struct Message {
    /// The join reference, if any.
    pub join_ref: Option<String>,
    /// The message reference used for replying.
    pub reference: Option<String>,
    /// The channel topic, e.g. `session:new`.
    pub topic: String,
    /// The event name, e.g. `phx_reply` or `send_prompt`.
    pub event: String,
    /// The JSON payload.
    pub payload: Value,
}

#[derive(Debug)]
enum ClientCommand {
    Send(Value),
}

/// WebSocket client that speaks the Phoenix Channels V1 protocol.
///
/// The server in this release uses `Phoenix.Socket.V1.JSONSerializer`, which
/// encodes each channel message as a JSON object with the keys
/// `join_ref`, `ref`, `topic`, `event`, and `payload`.
///
/// A background heartbeat task keeps the connection alive by sending a
/// `phoenix` heartbeat every 25 seconds, and the reader task automatically
/// replies to server-initiated heartbeats.
pub struct ChannelsClient {
    cmd_tx: mpsc::UnboundedSender<ClientCommand>,
    reply_rx: mpsc::UnboundedReceiver<Result<Message>>,
    _reader_handle: JoinHandle<()>,
    _writer_handle: JoinHandle<()>,
    _heartbeat_handle: JoinHandle<()>,
    ref_counter: u64,
    /// Map from topic to the join reference used for that topic.
    join_refs: HashMap<String, String>,
}

impl ChannelsClient {
    /// Connect to `ws://127.0.0.1:<port>/ws/websocket`.
    pub async fn connect(port: u16) -> Result<ChannelsClient> {
        let url = format!("ws://127.0.0.1:{}/ws/websocket", port);
        let (ws, _response) = connect_async(&url)
            .await
            .with_context(|| format!("connecting to {}", url))?;
        let (sink, stream) = ws.split();

        let (cmd_tx, cmd_rx) = mpsc::unbounded_channel::<ClientCommand>();
        let (reply_tx, reply_rx) = mpsc::unbounded_channel::<Result<Message>>();

        let writer_handle = tokio::spawn(writer_task(sink, cmd_rx));
        let reader_handle = tokio::spawn(reader_task(stream, reply_tx, cmd_tx.clone()));
        let heartbeat_handle = tokio::spawn(heartbeat_task(cmd_tx.clone()));

        Ok(ChannelsClient {
            cmd_tx,
            reply_rx,
            _reader_handle: reader_handle,
            _writer_handle: writer_handle,
            _heartbeat_handle: heartbeat_handle,
            ref_counter: 1,
            join_refs: HashMap::new(),
        })
    }

    /// Join a Phoenix Channel topic.
    ///
    /// Sends a `phx_join` message and waits for a `phx_reply` with
    /// `{"status": "ok"}` on the same topic.
    pub async fn join(&mut self, topic: &str) -> Result<()> {
        let reference = self.next_reference();
        let join_ref = reference.clone();
        self.join_refs.insert(topic.to_string(), join_ref.clone());

        let msg = json!({
            "join_ref": join_ref,
            "ref": reference,
            "topic": topic,
            "event": "phx_join",
            "payload": {}
        });
        self.send_json(msg).await?;

        loop {
            let msg = self.recv().await?;
            if msg.topic == topic && msg.event == "phx_reply" {
                let status = msg.payload.get("status").and_then(|v| v.as_str());
                if status == Some("ok") {
                    return Ok(());
                }
                return Err(anyhow!("join failed: {:?}", msg.payload));
            }
        }
    }

    /// Send an event with a JSON payload on `topic`.
    pub async fn send(&mut self, topic: &str, event: &str, payload: Value) -> Result<()> {
        let reference = self.next_reference();
        let join_ref = self.join_refs.get(topic).cloned().unwrap_or_default();

        let msg = json!({
            "join_ref": join_ref,
            "ref": reference,
            "topic": topic,
            "event": event,
            "payload": payload
        });
        self.send_json(msg).await
    }

    /// Receive the next non-heartbeat message from the WebSocket.
    pub async fn recv(&mut self) -> Result<Message> {
        loop {
            match self.reply_rx.recv().await {
                Some(Ok(msg)) => {
                    // Filter out heartbeat replies on the "phoenix" topic.
                    if msg.topic == "phoenix" && msg.event == "phx_reply" {
                        continue;
                    }
                    return Ok(msg);
                }
                Some(Err(e)) => return Err(e),
                None => return Err(anyhow!("websocket stream ended")),
            }
        }
    }

    async fn send_json(&mut self, value: Value) -> Result<()> {
        self.cmd_tx
            .send(ClientCommand::Send(value))
            .context("websocket command channel closed")?;
        Ok(())
    }

    fn next_reference(&mut self) -> String {
        let r = self.ref_counter;
        self.ref_counter += 1;
        r.to_string()
    }
}

async fn writer_task(
    mut sink: futures_util::stream::SplitSink<
        WebSocketStream<MaybeTlsStream<TcpStream>>,
        WsMessage,
    >,
    mut cmd_rx: mpsc::UnboundedReceiver<ClientCommand>,
) {
    while let Some(cmd) = cmd_rx.recv().await {
        match cmd {
            ClientCommand::Send(value) => {
                let text = match serde_json::to_string(&value) {
                    Ok(t) => t,
                    Err(_) => continue,
                };
                if sink.send(WsMessage::Text(text.into())).await.is_err() {
                    break;
                }
            }
        }
    }
    let _ = sink.close().await;
}

async fn reader_task(
    mut stream: futures_util::stream::SplitStream<WebSocketStream<MaybeTlsStream<TcpStream>>>,
    reply_tx: mpsc::UnboundedSender<Result<Message>>,
    cmd_tx: mpsc::UnboundedSender<ClientCommand>,
) {
    while let Some(item) = stream.next().await {
        match item {
            Ok(WsMessage::Text(text)) => {
                let reply = match parse_phoenix_message(&text) {
                    Ok(msg) => {
                        // Reply to server-initiated heartbeats immediately.
                        if msg.topic == "phoenix" && msg.event == "heartbeat" {
                            let reply = json!({
                                "join_ref": null,
                                "ref": msg.reference.unwrap_or_default(),
                                "topic": "phoenix",
                                "event": "heartbeat",
                                "payload": {}
                            });
                            let _ = cmd_tx.send(ClientCommand::Send(reply));
                            continue;
                        }
                        Ok(msg)
                    }
                    Err(e) => Err(e),
                };
                if reply_tx.send(reply).is_err() {
                    break;
                }
            }
            Ok(WsMessage::Binary(data)) => {
                let text = String::from_utf8_lossy(&data);
                let reply = parse_phoenix_message(&text);
                if reply_tx.send(reply).is_err() {
                    break;
                }
            }
            Ok(WsMessage::Close(_)) => {
                let _ = reply_tx.send(Err(anyhow!("websocket closed")));
                break;
            }
            Ok(other) => {
                let _ = reply_tx.send(Err(anyhow!("unexpected websocket message: {:?}", other)));
            }
            Err(e) => {
                let _ = reply_tx.send(Err(anyhow::Error::from(e).context("websocket error")));
                break;
            }
        }
    }
}

async fn heartbeat_task(cmd_tx: mpsc::UnboundedSender<ClientCommand>) {
    let mut ticker = interval(Duration::from_secs(25));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);

    loop {
        ticker.tick().await;
        let heartbeat = json!({
            "join_ref": null,
            "ref": "hb",
            "topic": "phoenix",
            "event": "heartbeat",
            "payload": {}
        });
        if cmd_tx.send(ClientCommand::Send(heartbeat)).is_err() {
            break;
        }
    }
}

fn parse_phoenix_message(text: &str) -> Result<Message> {
    let value: Value = serde_json::from_str(text).context("parsing phoenix message")?;

    let get_string = |key: &str| {
        value
            .get(key)
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    };

    let topic = get_string("topic").ok_or_else(|| anyhow!("missing or non-string topic field"))?;
    let event = get_string("event").ok_or_else(|| anyhow!("missing or non-string event field"))?;

    let join_ref = get_string("join_ref");
    let reference = get_string("ref");
    let payload = value.get("payload").cloned().unwrap_or(Value::Null);

    Ok(Message {
        join_ref,
        reference,
        topic,
        event,
        payload,
    })
}
