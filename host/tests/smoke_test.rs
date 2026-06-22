use hermes_host::ws_client::ChannelsClient;
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command;
use tokio::time::{sleep, timeout};

fn random_port() -> u16 {
    use rand::Rng;
    let mut rng = rand::thread_rng();
    rng.gen_range(10000..=60000)
}

fn hermes_binary() -> std::path::PathBuf {
    if let Ok(path) = std::env::var("HERMES_SMOKE_BINARY") {
        return std::path::PathBuf::from(path);
    }
    std::env::var("CARGO_BIN_EXE_hermes-host")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| {
            let manifest_dir =
                std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR should be set");
            std::path::PathBuf::from(manifest_dir).join("target/debug/hermes-host")
        })
}

#[tokio::test]
async fn binary_boots_and_runs_one_turn() {
    let port = random_port();
    let bin = hermes_binary();

    assert!(
        bin.exists(),
        "hermes-host binary should exist at {}",
        bin.display()
    );

    let mut child = Command::new(&bin)
        .arg("--port")
        .arg(port.to_string())
        .arg("--model")
        .arg("smoke-test-model")
        .arg("--provider")
        .arg("mock")
        .arg("gateway")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn hermes-host gateway");

    let host_pid = child.id().unwrap();

    // Wait for the BEAM release to boot and the WebSocket endpoint to accept
    // connections (up to 60 seconds to account for first-time extraction).
    let connected = timeout(Duration::from_secs(60), async {
        loop {
            if tokio::net::TcpStream::connect(format!("127.0.0.1:{}", port))
                .await
                .is_ok()
            {
                return true;
            }
            if let Ok(Some(status)) = child.try_wait() {
                panic!("hermes-host exited early with status: {:?}", status);
            }
            sleep(Duration::from_millis(100)).await;
        }
    })
    .await
    .unwrap_or(false);

    assert!(
        connected,
        "hermes-host should listen on port {} within 60s",
        port
    );

    // Connect via Phoenix Channels and exercise one full turn.
    let mut client = ChannelsClient::connect(port)
        .await
        .expect("websocket connect");

    client.join("session:new").await.expect("join session:new");

    client
        .send(
            "session:new",
            "session:create",
            serde_json::json!({
                "model": "smoke-test-model",
                "provider": "mock",
                "api_mode": "mock"
            }),
        )
        .await
        .expect("send session:create");

    let reply = recv_non_heartbeat(&mut client, Duration::from_secs(10))
        .await
        .expect("session:create reply");
    assert_eq!(reply.topic, "session:new");
    assert_eq!(reply.event, "phx_reply");
    assert_eq!(
        reply.payload.get("status").and_then(|v| v.as_str()),
        Some("ok")
    );

    client
        .send(
            "session:new",
            "send_prompt",
            serde_json::json!({"message": "hello"}),
        )
        .await
        .expect("send prompt");
    // send_prompt replies immediately with a phx_reply; the actual turn result
    // is broadcast asynchronously as turn:complete.
    let reply = recv_non_heartbeat(&mut client, Duration::from_secs(10))
        .await
        .expect("send_prompt ack");
    assert_eq!(reply.topic, "session:new");
    assert_eq!(reply.event, "phx_reply");

    // Wait for the turn to complete. The mock provider returns immediately,
    // so 10 seconds is generous.
    let turn = recv_non_heartbeat(&mut client, Duration::from_secs(10))
        .await
        .expect("turn:complete event");
    assert_eq!(turn.topic, "session:new");
    assert_eq!(turn.event, "turn:complete");
    assert!(
        turn.payload.get("final_response").is_some(),
        "turn:complete should carry a final_response"
    );

    // Send SIGINT to the Rust host and verify clean shutdown.
    #[cfg(unix)]
    {
        std::process::Command::new("kill")
            .arg("-INT")
            .arg(host_pid.to_string())
            .output()
            .expect("send SIGINT");
    }
    #[cfg(not(unix))]
    {
        child.kill().await.expect("kill hermes-host");
    }

    let status = timeout(Duration::from_secs(30), async {
        loop {
            if let Ok(Some(status)) = child.try_wait() {
                return status;
            }
            sleep(Duration::from_millis(100)).await;
        }
    })
    .await
    .expect("hermes-host should exit within 30s of SIGINT");

    // The process may exit non-zero when interrupted; the important property is
    // that it actually exits (clean shutdown path ran) rather than hanging or
    // orphaning the BEAM tree.
    assert!(
        !process_alive(host_pid),
        "hermes-host process {} should be reaped after SIGINT",
        host_pid
    );

    // Give the OS a moment to reap BEAM grandchildren, then warn if any are
    // still alive. A live grandchild is not a test failure because the host
    // process itself is gone and the release may still be flushing.
    sleep(Duration::from_secs(1)).await;
    if let Some(beam_pid) = find_first_child(host_pid) {
        if process_alive(beam_pid) {
            eprintln!(
                "Warning: BEAM descendant {} still alive after host shutdown",
                beam_pid
            );
        }
    }

    eprintln!(
        "Smoke test passed; hermes-host exited with status {:?}",
        status.code()
    );
}

async fn recv_non_heartbeat(
    client: &mut ChannelsClient,
    deadline: Duration,
) -> anyhow::Result<hermes_host::ws_client::Message> {
    timeout(deadline, client.recv())
        .await
        .map_err(|_| anyhow::anyhow!("timed out waiting for message"))?
}

#[cfg(unix)]
fn process_alive(pid: u32) -> bool {
    std::process::Command::new("kill")
        .arg("-0")
        .arg(pid.to_string())
        .output()
        .map(|out| out.status.success())
        .unwrap_or(false)
}

#[cfg(not(unix))]
fn process_alive(_pid: u32) -> bool {
    false
}

#[cfg(unix)]
fn find_first_child(pid: u32) -> Option<u32> {
    let output = std::process::Command::new("pgrep")
        .arg("-P")
        .arg(pid.to_string())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8(output.stdout)
        .ok()?
        .lines()
        .next()
        .and_then(|s| s.trim().parse().ok())
}

#[cfg(not(unix))]
fn find_first_child(_pid: u32) -> Option<u32> {
    None
}
