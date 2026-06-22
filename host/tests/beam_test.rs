use hermes_host::beam::BeamProcess;
use hermes_host::ws_client::ChannelsClient;
use rand::Rng;
use std::path::PathBuf;
use std::time::Duration;
use tokio::time::timeout;

fn random_port() -> u16 {
    let mut rng = rand::thread_rng();
    rng.gen_range(10000..=60000)
}

fn temp_cache_root() -> PathBuf {
    tempfile::tempdir().expect("creating temp dir").into_path()
}

#[tokio::test]
async fn extract_creates_cache_dir_with_release_files() {
    let root = temp_cache_root();
    let cache_dir = BeamProcess::extract_to(&root).await.unwrap();

    assert!(cache_dir.exists());
    assert!(cache_dir.join("hermes/bin/hermes").exists());
    assert!(cache_dir.join("hermes/bin/server").exists());
}

#[tokio::test]
async fn extract_is_idempotent() {
    let root = temp_cache_root();

    let dir1 = BeamProcess::extract_to(&root).await.unwrap();
    let dir2 = BeamProcess::extract_to(&root).await.unwrap();

    assert_eq!(dir1, dir2);
    assert!(dir1.join("hermes/bin/hermes").exists());
}

#[tokio::test]
async fn spawn_starts_a_beam_process() {
    let root = temp_cache_root();
    let cache_dir = BeamProcess::extract_to(&root).await.unwrap();
    let port = random_port();

    let mut beam = BeamProcess::spawn(&cache_dir, port).await.unwrap();
    beam.wait_for_port().await.unwrap();
    beam.shutdown().await.unwrap();
}

#[tokio::test]
async fn wait_for_port_succeeds_when_server_is_up() {
    let root = temp_cache_root();
    let cache_dir = BeamProcess::extract_to(&root).await.unwrap();
    let port = random_port();

    let mut beam = BeamProcess::spawn(&cache_dir, port).await.unwrap();
    beam.wait_for_port().await.unwrap();
    beam.shutdown().await.unwrap();
}

#[tokio::test]
async fn shutdown_stops_the_beam_process() {
    let root = temp_cache_root();
    let cache_dir = BeamProcess::extract_to(&root).await.unwrap();
    let port = random_port();

    let mut beam = BeamProcess::spawn(&cache_dir, port).await.unwrap();
    beam.wait_for_port().await.unwrap();
    beam.shutdown().await.unwrap();

    tokio::time::sleep(Duration::from_millis(500)).await;
    let result = tokio::net::TcpStream::connect(format!("127.0.0.1:{}", port)).await;
    assert!(
        result.is_err(),
        "port {} should be closed after shutdown",
        port
    );
}

#[tokio::test]
async fn integration_extract_spawn_wait_connect_join_send_receive() {
    let root = temp_cache_root();
    let cache_dir = BeamProcess::extract_to(&root).await.unwrap();
    let port = random_port();

    let mut beam = BeamProcess::spawn(&cache_dir, port).await.unwrap();
    beam.wait_for_port().await.unwrap();

    let mut client = ChannelsClient::connect(port).await.unwrap();
    client.join("session:new").await.unwrap();

    // Create a session so we have somewhere to send a prompt.
    client
        .send(
            "session:new",
            "session:create",
            serde_json::json!({
                "model": "claude-sonnet-4-20250514",
                "provider": "anthropic",
                "api_mode": "streaming"
            }),
        )
        .await
        .unwrap();

    let reply = timeout(Duration::from_secs(10), client.recv())
        .await
        .expect("session:create reply should arrive")
        .expect("recv should succeed");

    assert_eq!(reply.topic, "session:new");
    assert_eq!(reply.event, "phx_reply");
    assert_eq!(
        reply.payload.get("status").and_then(|v| v.as_str()),
        Some("ok")
    );

    // Send a prompt on the same topic; the channel's assigns now hold the
    // real session id after session:create.
    client
        .send(
            "session:new",
            "send_prompt",
            serde_json::json!({"message": "hello"}),
        )
        .await
        .unwrap();

    let reply = timeout(Duration::from_secs(10), client.recv())
        .await
        .expect("send_prompt reply should arrive")
        .expect("recv should succeed");

    assert_eq!(reply.topic, "session:new");
    assert_eq!(reply.event, "phx_reply");
    assert_eq!(
        reply.payload.get("status").and_then(|v| v.as_str()),
        Some("ok")
    );

    beam.shutdown().await.unwrap();
}
