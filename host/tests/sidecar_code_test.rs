use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::process::Stdio;
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::time::timeout;

/// Mirror of the code-execution protocol so tests do not depend on private shapes.
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
        code: String,
        language: String,
        #[serde(default)]
        timeout_secs: u64,
        #[serde(default)]
        memory_limit_mb: u64,
    },
    ExecuteWithTools {
        code: String,
        allowed_tools: Vec<String>,
        #[serde(default)]
        timeout_secs: u64,
        #[serde(default)]
        memory_limit_mb: u64,
    },
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
    Error {
        message: String,
    },
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
            .arg("code-execution")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn hermes-sidecar code-execution");

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
        drop(self.stdin);
        let _ = self.child.wait().await;
        Ok(())
    }
}

#[tokio::test]
async fn execute_simple_python() -> Result<()> {
    let mut sidecar = SidecarHandle::new().await?;

    let resp = sidecar
        .request(Request::Execute {
            code: "print('hello')".to_string(),
            language: "python".to_string(),
            timeout_secs: 10,
            memory_limit_mb: 256,
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
async fn execute_simple_elixir() -> Result<()> {
    let mut sidecar = SidecarHandle::new().await?;

    let resp = sidecar
        .request(Request::Execute {
            code: "IO.puts(1 + 2)".to_string(),
            language: "elixir".to_string(),
            timeout_secs: 10,
            memory_limit_mb: 256,
        })
        .await?;

    match resp.body {
        Response::ExecuteResult {
            stdout,
            stderr,
            exit_code,
        } => {
            assert_eq!(exit_code, 0);
            assert!(stdout.contains("3"));
            assert!(stderr.is_empty());
        }
        other => panic!("unexpected response: {:?}", other),
    }

    sidecar.shutdown().await?;
    Ok(())
}

#[tokio::test]
async fn execute_captures_syntax_error() -> Result<()> {
    let mut sidecar = SidecarHandle::new().await?;

    let resp = sidecar
        .request(Request::Execute {
            code: "print(".to_string(),
            language: "python".to_string(),
            timeout_secs: 10,
            memory_limit_mb: 256,
        })
        .await?;

    match resp.body {
        Response::ExecuteResult {
            stderr,
            exit_code,
            stdout,
        } => {
            assert_ne!(exit_code, 0);
            assert!(stderr.contains("SyntaxError"));
            assert!(stdout.is_empty());
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
            code: "while True: pass".to_string(),
            language: "python".to_string(),
            timeout_secs: 1,
            memory_limit_mb: 256,
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
async fn execute_with_tools_mock_rpc() -> Result<()> {
    let mut sidecar = SidecarHandle::new().await?;

    let resp = sidecar
        .request(Request::ExecuteWithTools {
            code: "print(web_search('foo'))".to_string(),
            allowed_tools: vec!["web_search".to_string()],
            timeout_secs: 10,
            memory_limit_mb: 256,
        })
        .await?;

    match resp.body {
        Response::ExecuteResult {
            stdout,
            stderr,
            exit_code,
        } => {
            assert_eq!(exit_code, 0);
            assert!(stdout.contains("'ok': True"));
            assert!(stdout.contains("'tool': 'web_search'"));
            assert!(stderr.is_empty());
        }
        other => panic!("unexpected response: {:?}", other),
    }

    sidecar.shutdown().await?;
    Ok(())
}

#[tokio::test]
async fn invalid_request_returns_error() -> Result<()> {
    let mut sidecar = SidecarHandle::new().await?;

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

#[tokio::test]
async fn concurrent_requests_are_independent() -> Result<()> {
    let mut sidecar = SidecarHandle::new().await?;

    let id1 = sidecar
        .send(Request::Execute {
            code: "import time; time.sleep(2)".to_string(),
            language: "python".to_string(),
            timeout_secs: 30,
            memory_limit_mb: 256,
        })
        .await;

    let id2 = sidecar
        .send(Request::Execute {
            code: "print('quick')".to_string(),
            language: "python".to_string(),
            timeout_secs: 10,
            memory_limit_mb: 256,
        })
        .await;

    let resp2 = timeout(Duration::from_secs(5), sidecar.recv()).await??;
    assert_eq!(resp2.id, id2);
    match resp2.body {
        Response::ExecuteResult {
            stdout, exit_code, ..
        } => {
            assert_eq!(exit_code, 0);
            assert!(stdout.contains("quick"));
        }
        other => panic!("unexpected response: {:?}", other),
    }

    let resp1 = timeout(Duration::from_secs(5), sidecar.recv()).await??;
    assert_eq!(resp1.id, id1);
    match resp1.body {
        Response::ExecuteResult { exit_code, .. } => {
            assert_eq!(exit_code, 0, "long request should complete successfully");
        }
        other => panic!("unexpected response: {:?}", other),
    }

    sidecar.shutdown().await?;
    Ok(())
}
