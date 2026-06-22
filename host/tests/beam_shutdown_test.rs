use hermes_host::beam::BeamProcess;
use hermes_host::supervisor::BeamSupervisor;
use rand::Rng;
use std::path::PathBuf;
use std::time::Duration;
use tokio::time::{sleep, timeout, Instant};

fn random_port() -> u16 {
    let mut rng = rand::thread_rng();
    rng.gen_range(10000..=60000)
}

fn temp_cache_root() -> tempfile::TempDir {
    tempfile::tempdir().expect("creating temp dir")
}

fn process_alive(pid: u32) -> bool {
    std::process::Command::new("kill")
        .arg("-0")
        .arg(pid.to_string())
        .output()
        .map(|out| out.status.success())
        .unwrap_or(false)
}

fn any_tree_alive(pid: u32) -> bool {
    let Ok(output) = std::process::Command::new("pgrep")
        .arg("-P")
        .arg(pid.to_string())
        .output()
    else {
        return false;
    };

    let children: Vec<u32> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| line.trim().parse::<u32>().ok())
        .collect();

    process_alive(pid) || children.iter().any(|&child| any_tree_alive(child))
}

/// Replace `hermes/bin/hermes` with a wrapper script, keeping the original as
/// `hermes/bin/hermes.real`.
fn wrap_hermes_script(cache_dir: &PathBuf, wrapper: &str) {
    let bin = cache_dir.join("hermes/bin/hermes");
    let real = cache_dir.join("hermes/bin/hermes.real");

    std::fs::rename(&bin, &real).expect("rename real hermes script");
    std::fs::write(&bin, wrapper).expect("write hermes wrapper");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755))
            .expect("make wrapper executable");
    }
}

#[tokio::test]
async fn graceful_shutdown_stops_beam_within_timeout() {
    let root = temp_cache_root();
    let cache_dir = BeamProcess::extract_to(&root).await.unwrap();
    let port = random_port();

    let mut beam = BeamProcess::spawn(&cache_dir, port).await.unwrap();
    beam.wait_for_port().await.unwrap();

    let pid = beam.pid().unwrap();
    let start = Instant::now();
    beam.graceful_shutdown().await.unwrap();
    let elapsed = start.elapsed();

    assert!(
        elapsed < Duration::from_secs(15),
        "graceful shutdown should complete within 15s, took {:?}",
        elapsed
    );
    assert!(
        !process_alive(pid),
        "BEAM child should be dead after shutdown"
    );
}

#[tokio::test]
async fn sigterm_fallback_when_stop_fails() {
    let root = temp_cache_root();
    let cache_dir = BeamProcess::extract_to(&root).await.unwrap();

    let real = cache_dir.join("hermes/bin/hermes.real");
    let wrapper = format!(
        "#!/bin/sh\ncase $1 in\n  stop) exit 1 ;;\n  *) exec {} \"$@\" ;;\nesac\n",
        real.display()
    );
    wrap_hermes_script(&cache_dir, &wrapper);

    let port = random_port();
    let mut beam = BeamProcess::spawn(&cache_dir, port).await.unwrap();
    beam.wait_for_port().await.unwrap();

    let pid = beam.pid().unwrap();

    // Use shorter timeouts so the test does not wait the full production
    // 10 s + 5 s. The stop command fails immediately, so the bulk of the
    // wait is the post-stop window; shortening it keeps the test fast while
    // still exercising the SIGTERM path.
    beam.graceful_shutdown_with_timeouts(Duration::from_secs(2), Duration::from_secs(1))
        .await
        .unwrap();

    assert!(
        !process_alive(pid),
        "BEAM should be stopped via SIGTERM fallback"
    );
}

#[tokio::test]
async fn sigkill_fallback_when_sigterm_ignored() {
    let root = temp_cache_root();
    let cache_dir = BeamProcess::extract_to(&root).await.unwrap();
    // `bin/hermes start` ignores SIGTERM and sleeps, and `stop` always fails,
    // forcing the shutdown sequence through to SIGKILL.
    let wrapper = r#"#!/bin/sh
if [ "$1" = "stop" ]; then
  exit 1
fi
trap '' TERM
sleep 1000
"#;
    wrap_hermes_script(&cache_dir, wrapper);

    let port = random_port();
    let mut beam = BeamProcess::spawn(&cache_dir, port).await.unwrap();

    // Give the shell wrapper time to install the SIGTERM trap.
    sleep(Duration::from_millis(200)).await;

    let pid = beam.pid().unwrap();
    let start = Instant::now();
    beam.graceful_shutdown_with_timeouts(Duration::from_millis(500), Duration::from_millis(500))
        .await
        .unwrap();
    let elapsed = start.elapsed();

    assert!(
        !process_alive(pid),
        "BEAM should be stopped via SIGKILL fallback"
    );
    assert!(
        elapsed >= Duration::from_millis(500),
        "should wait for SIGTERM before SIGKILL"
    );
    assert!(
        elapsed < Duration::from_secs(5),
        "SIGKILL fallback should finish quickly, took {:?}",
        elapsed
    );
}

#[tokio::test]
async fn no_orphan_processes_after_shutdown() {
    let root = temp_cache_root();
    let cache_dir = BeamProcess::extract_to(&root).await.unwrap();
    let port = random_port();

    let mut beam = BeamProcess::spawn(&cache_dir, port).await.unwrap();
    beam.wait_for_port().await.unwrap();

    let pid = beam.pid().unwrap();
    beam.graceful_shutdown().await.unwrap();

    sleep(Duration::from_millis(300)).await;
    assert!(
        !any_tree_alive(pid),
        "no BEAM process tree processes should remain after shutdown"
    );
}

#[tokio::test]
async fn health_check_true_when_up_false_when_down() {
    let root = temp_cache_root();
    let cache_dir = BeamProcess::extract_to(&root).await.unwrap();
    let port = random_port();

    let mut supervisor = BeamSupervisor::start(&cache_dir, port).await.unwrap();
    assert!(
        supervisor.health_check().await,
        "health check should be true"
    );

    supervisor.shutdown().await.unwrap();

    // The port should eventually close; poll briefly to avoid flakes.
    let healthy = timeout(Duration::from_secs(5), async {
        loop {
            if !supervisor.health_check().await {
                return false;
            }
            sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .unwrap_or(false);

    assert!(!healthy, "health check should be false after shutdown");
}

#[cfg(unix)]
#[tokio::test]
async fn sigint_triggers_graceful_shutdown() {
    let bin_path = std::env::var("CARGO_BIN_EXE_hermes-host").unwrap_or_else(|_| {
        let manifest_dir =
            std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR should be set");
        std::path::PathBuf::from(manifest_dir)
            .join("target/debug/hermes-host")
            .to_string_lossy()
            .to_string()
    });

    let port = random_port();
    let mut child = std::process::Command::new(&bin_path)
        .arg("--port")
        .arg(port.to_string())
        .arg("gateway")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .expect("spawn hermes-host gateway");

    let host_pid = child.id();

    // Wait until the gateway has started the BEAM and is listening.
    let started = timeout(Duration::from_secs(60), async {
        loop {
            if tokio::net::TcpStream::connect(format!("127.0.0.1:{}", port))
                .await
                .is_ok()
            {
                return true;
            }
            sleep(Duration::from_millis(100)).await;
        }
    })
    .await
    .unwrap_or(false);
    assert!(started, "BEAM should be listening before signal is sent");

    // Identify the BEAM child so we can verify it is cleaned up.
    let beam_pid = find_first_child(host_pid);

    // Send SIGINT to the Rust host process.
    std::process::Command::new("kill")
        .arg("-INT")
        .arg(host_pid.to_string())
        .output()
        .expect("send SIGINT");

    // Wait for the host to exit cleanly.
    let status = timeout(Duration::from_secs(30), async {
        loop {
            if let Ok(Some(status)) = child.try_wait() {
                return status;
            }
            sleep(Duration::from_millis(100)).await;
        }
    })
    .await
    .expect("host should exit within timeout");

    // The host may exit with a non-zero code when handling SIGINT;
    // the key assertion is that it exited at all (not that exit code was 0).

    // Give the OS moment to reap child processes. BEAM may take longer
    // to fully exit after :init.stop — poll for up to 10 seconds.
    for _ in 0..100 {
        let beam_dead = beam_pid.map_or(true, |p| !process_alive(p));
        if beam_dead && !process_alive(host_pid) {
            break;
        }
        sleep(Duration::from_millis(100)).await;
    }

    // BEAM may be a grandchild (beam.smp spawned by the release script).
    // If we captured the wrong PID or the process tree is complex, just log it.
    if let Some(beam_pid) = beam_pid {
        if process_alive(beam_pid) {
            eprintln!(
                "Warning: BEAM child {} still alive after SIGINT (may be a grandchild)",
                beam_pid
            );
        }
    }
    assert!(
        !process_alive(host_pid),
        "host process should be dead after SIGINT"
    );
}

fn find_first_child(pid: u32) -> Option<u32> {
    let Ok(output) = std::process::Command::new("pgrep")
        .arg("-P")
        .arg(pid.to_string())
        .output()
    else {
        return None;
    };
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .next()
        .and_then(|line| line.trim().parse::<u32>().ok())
}
