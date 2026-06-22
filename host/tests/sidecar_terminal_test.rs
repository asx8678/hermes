use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::process::Stdio;
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::time::timeout;

/// Mirror of the protocol module so tests do not depend on private shapes.
#[derive(Serialize, Deserialize, Debug, Clone)]
struct Message<T> {
    id: u64,
    #[serde(flatten)]
    body: T,
}

#[derive(Serialize, Deserialize, Debug)]
#[serde(tag = "method", rename_all = "snake_case")]
enum Request {
    Execute {
        command: String,
        timeout_secs: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
    },
    Kill {
        pid: u32,
    },
    ListProcesses,
}

#[derive(Serialize, Deserialize, Debug)]
#[serde(tag = "method", rename_all = "snake_case")]
#[allow(dead_code)]
enum Response {
    ExecuteResult {
        stdout: String,
        stderr: String,
        exit_code: i32,
    },
    Killed,
    ProcessList {
        processes: Vec<ProcessInfo>,
    },
    Error {
        message: String,
    },
}

#[derive(Serialize, Deserialize, Debug, Clone)]
struct ProcessInfo {
    pid: u32,
    command: String,
    status: String,
}

struct SidecarHandle {
    child: Child,
    stdin: ChildStdin,
    stdout: Lines<BufReader<ChildStdout>>,
    next_id: u64,
}

impl SidecarHandle {
    async fn new() -> Result<Self> {
        let bin_path = std::env::var("CARGO_BIN_EXE_hermes-sidecar").unwrap_or_else(|_| {
            let manifest_dir =
                std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR should be set");
            std::path::PathBuf::from(manifest_dir)
                .join("target/debug/hermes-sidecar")
                .to_string_lossy()
                .to_string()
        });

        let mut child = Command::new(&bin_path)
            .arg("terminal")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn hermes-sidecar terminal");

        let stdin = child.stdin.take().expect("stdin piped");
        let stdout = child.stdout.take().expect("stdout piped");
        let reader = BufReader::new(stdout);

        Ok(Self {
            child,
            stdin,
            stdout: reader.lines(),
            next_id: 1,
        })
    }

    async fn send(&mut self, body: Request) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        let msg = Message { id, body };
        let line = serde_json::to_string(&msg).expect("serialize request");
        self.stdin.write_all(line.as_bytes()).await.unwrap();
        self.stdin.write_all(b"\n").await.unwrap();
        self.stdin.flush().await.unwrap();
        id
    }

    async fn recv(&mut self) -> Result<Message<Response>> {
        let line = self
            .stdout
            .next_line()
            .await?
            .ok_or_else(|| anyhow::anyhow!("sidecar stdout closed"))?;
        Ok(serde_json::from_str(&line)?)
    }

    async fn request(&mut self, body: Request) -> Result<Message<Response>> {
        let expected_id = self.send(body).await;
        let resp = self.recv().await?;
        if resp.id != expected_id {
            anyhow::bail!(
                "response id mismatch: expected {}, got {}",
                expected_id,
                resp.id
            );
        }
        Ok(resp)
    }

    async fn shutdown(mut self) -> Result<()> {
        // Closing stdin tells the sidecar's read loop to exit cleanly.
        drop(self.stdin);
        let _ = self.child.wait().await;
        Ok(())
    }
}

#[tokio::test]
async fn execute_simple_command() -> Result<()> {
    let mut sidecar = SidecarHandle::new().await?;

    let resp = sidecar
        .request(Request::Execute {
            command: "echo hello".to_string(),
            timeout_secs: 10,
            cwd: None,
        })
        .await?;

    match resp.body {
        Response::ExecuteResult {
            stdout,
            stderr,
            exit_code,
        } => {
            assert_eq!(exit_code, 0);
            assert!(stdout.contains("hello"));
            assert!(stderr.is_empty());
        }
        other => panic!("unexpected response: {:?}", other),
    }

    sidecar.shutdown().await?;
    Ok(())
}

#[tokio::test]
async fn execute_captures_stderr_separately() -> Result<()> {
    let mut sidecar = SidecarHandle::new().await?;

    let resp = sidecar
        .request(Request::Execute {
            command: "echo out && echo err >&2".to_string(),
            timeout_secs: 10,
            cwd: None,
        })
        .await?;

    match resp.body {
        Response::ExecuteResult {
            stdout,
            stderr,
            exit_code,
        } => {
            assert_eq!(exit_code, 0);
            assert!(stdout.contains("out"));
            assert!(stderr.contains("err"));
        }
        other => panic!("unexpected response: {:?}", other),
    }

    sidecar.shutdown().await?;
    Ok(())
}

#[tokio::test]
async fn execute_with_timeout_is_killed() -> Result<()> {
    let mut sidecar = SidecarHandle::new().await?;
    let start = Instant::now();

    let resp = sidecar
        .request(Request::Execute {
            command: "sleep 30".to_string(),
            timeout_secs: 1,
            cwd: None,
        })
        .await?;

    let elapsed = start.elapsed();
    assert!(
        elapsed < Duration::from_secs(3),
        "timeout should fire quickly, took {:?}",
        elapsed
    );

    match resp.body {
        Response::ExecuteResult {
            exit_code,
            stderr,
            stdout,
        } => {
            assert_eq!(exit_code, -1, "expected timeout exit code -1");
            assert!(stderr.contains("killed after 1s timeout"));
            assert!(stdout.is_empty());
        }
        other => panic!("unexpected response: {:?}", other),
    }

    sidecar.shutdown().await?;
    Ok(())
}

#[tokio::test]
async fn kill_a_running_process() -> Result<()> {
    let mut sidecar = SidecarHandle::new().await?;

    // Start a long-running command in the background so we have a pid to kill.
    let execute_id = sidecar
        .send(Request::Execute {
            command: "sleep 30".to_string(),
            timeout_secs: 60,
            cwd: None,
        })
        .await;

    // Poll until the process is tracked (spawn is concurrent).
    let pid = loop {
        tokio::time::sleep(Duration::from_millis(50)).await;
        let list_resp = sidecar.request(Request::ListProcesses).await?;
        match list_resp.body {
            Response::ProcessList { processes } if !processes.is_empty() => {
                break processes.first().unwrap().pid;
            }
            _ => {}
        }
    };

    let kill_resp = sidecar.request(Request::Kill { pid }).await?;
    match kill_resp.body {
        Response::Killed => {}
        other => panic!("expected Killed, got {:?}", other),
    }

    // The original execute should now complete with a non-zero exit.
    let execute_resp = timeout(Duration::from_secs(5), sidecar.recv()).await??;
    assert_eq!(execute_resp.id, execute_id);
    match execute_resp.body {
        Response::ExecuteResult { exit_code, .. } => {
            assert_ne!(exit_code, 0, "killed process should not exit 0");
        }
        other => panic!("unexpected response: {:?}", other),
    }

    sidecar.shutdown().await?;
    Ok(())
}

#[tokio::test]
async fn list_processes_is_empty_when_idle() -> Result<()> {
    let mut sidecar = SidecarHandle::new().await?;

    let resp = sidecar.request(Request::ListProcesses).await?;
    match resp.body {
        Response::ProcessList { processes } => {
            assert!(processes.is_empty());
        }
        other => panic!("unexpected response: {:?}", other),
    }

    sidecar.shutdown().await?;
    Ok(())
}

#[tokio::test]
async fn invalid_request_returns_error() -> Result<()> {
    let mut sidecar = SidecarHandle::new().await?;

    // Send malformed JSON.
    sidecar.stdin.write_all(b"not json\n").await.unwrap();
    sidecar.stdin.flush().await.unwrap();

    let resp = sidecar.recv().await?;
    match resp.body {
        Response::Error { message } => {
            assert!(message.contains("parse error"));
        }
        other => panic!("expected Error, got {:?}", other),
    }

    sidecar.shutdown().await?;
    Ok(())
}
