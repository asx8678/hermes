use crate::sidecar::protocol::{Message, ProcessInfo, Request, Response};
use anyhow::{Context, Result};
use std::collections::HashMap;
use std::process::Stdio;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::mpsc;
use tokio::time::Duration;

/// Process metadata tracked by the sidecar.
struct TrackedProcess {
    pid: u32,
    command: String,
    status: String,
}

type Processes = Arc<tokio::sync::Mutex<HashMap<u32, TrackedProcess>>>;

/// Entry point for `hermes-sidecar terminal`.
///
/// Reads newline-delimited JSON requests from stdin and writes responses to
/// stdout. Each request is handled concurrently so a long-running `execute`
/// does not block `kill` or `list_processes`.
pub async fn run() -> Result<()> {
    let stdin = tokio::io::stdin();
    let reader = BufReader::new(stdin);
    let mut lines = reader.lines();

    let (response_tx, mut response_rx) = mpsc::channel::<Message<Response>>(64);

    // Single writer task owns stdout so concurrent handlers do not interleave.
    let writer_handle = {
        let mut stdout = tokio::io::stdout();
        tokio::spawn(async move {
            while let Some(msg) = response_rx.recv().await {
                if let Err(e) = write_message(&mut stdout, msg).await {
                    eprintln!("sidecar stdout write failed: {}", e);
                    break;
                }
            }
        })
    };

    let processes: Processes = Arc::new(tokio::sync::Mutex::new(HashMap::new()));

    while let Some(line) = lines.next_line().await? {
        let request: Message<Request> = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                let _ = response_tx
                    .send(Message {
                        id: 0,
                        body: Response::Error {
                            message: format!("parse error: {}", e),
                        },
                    })
                    .await;
                continue;
            }
        };

        let tx = response_tx.clone();
        let procs = processes.clone();
        tokio::spawn(async move {
            let response = handle_request(request.body, procs).await;
            let _ = tx
                .send(Message {
                    id: request.id,
                    body: response,
                })
                .await;
        });
    }

    drop(response_tx);
    writer_handle.await?;
    Ok(())
}

async fn write_message(stdout: &mut tokio::io::Stdout, msg: Message<Response>) -> Result<()> {
    let line = serde_json::to_string(&msg).context("serialize response")?;
    stdout.write_all(line.as_bytes()).await?;
    stdout.write_all(b"\n").await?;
    stdout.flush().await?;
    Ok(())
}

async fn handle_request(req: Request, processes: Processes) -> Response {
    match req {
        Request::Execute {
            command,
            timeout_secs,
            cwd,
        } => handle_execute(command, timeout_secs, cwd, processes).await,
        Request::Kill { pid } => handle_kill(pid, processes).await,
        Request::ListProcesses => handle_list(processes).await,
    }
}

async fn handle_execute(
    command: String,
    timeout_secs: u64,
    cwd: Option<String>,
    processes: Processes,
) -> Response {
    let mut cmd = Command::new("sh");
    cmd.arg("-c")
        .arg(&command)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    if let Some(cwd) = cwd {
        cmd.current_dir(&cwd);
    }

    #[cfg(unix)]
    {
        cmd.process_group(0);
    }

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            return Response::Error {
                message: format!("failed to spawn command: {}", e),
            };
        }
    };

    let pid = match child.id() {
        Some(id) => id,
        None => {
            let _ = child.kill().await;
            return Response::Error {
                message: "spawned process has no pid".to_string(),
            };
        }
    };

    {
        let mut procs = processes.lock().await;
        procs.insert(
            pid,
            TrackedProcess {
                pid,
                command: command.clone(),
                status: "running".to_string(),
            },
        );
    }

    let stdout = child.stdout.take().expect("stdout piped");
    let stderr = child.stderr.take().expect("stderr piped");

    let stdout_fut = read_pipe(stdout);
    let stderr_fut = read_pipe(stderr);

    let timeout = tokio::time::sleep(Duration::from_secs(timeout_secs));
    tokio::pin!(timeout);

    let result = tokio::select! {
        _ = &mut timeout => {
            let _ = kill_process_tree(pid).await;
            // Reap the child so it does not become a zombie.
            let _ = child.wait().await;
            let stdout = stdout_fut.await.unwrap_or_default();
            let stderr = format!(
                "{}\nkilled after {}s timeout",
                stderr_fut.await.unwrap_or_default(),
                timeout_secs
            );
            Response::ExecuteResult {
                stdout,
                stderr,
                exit_code: -1,
            }
        }
        status = child.wait() => {
            let stdout = stdout_fut.await.unwrap_or_default();
            let stderr = stderr_fut.await.unwrap_or_default();
            let exit_code = status.ok().and_then(|s| s.code()).unwrap_or(-1);
            Response::ExecuteResult { stdout, stderr, exit_code }
        }
    };

    {
        let mut procs = processes.lock().await;
        procs.remove(&pid);
    }

    result
}

async fn handle_kill(pid: u32, processes: Processes) -> Response {
    let mut procs = processes.lock().await;
    if procs.remove(&pid).is_some() {
        match kill_process_tree(pid).await {
            Ok(_) => Response::Killed,
            Err(e) => Response::Error {
                message: format!("failed to kill {}: {}", pid, e),
            },
        }
    } else {
        Response::Error {
            message: format!("pid {} not found", pid),
        }
    }
}

async fn handle_list(processes: Processes) -> Response {
    let procs = processes.lock().await;
    let list = procs
        .values()
        .map(|p| ProcessInfo {
            pid: p.pid,
            command: p.command.clone(),
            status: p.status.clone(),
        })
        .collect();
    Response::ProcessList { processes: list }
}

async fn read_pipe<R>(mut reader: R) -> Result<String>
where
    R: AsyncRead + Unpin,
{
    let mut buf = Vec::new();
    reader.read_to_end(&mut buf).await?;
    Ok(String::from_utf8_lossy(&buf).to_string())
}

// ---------------------------------------------------------------------------
// Process tree termination
// ---------------------------------------------------------------------------

/// Kill a process and, on Unix, its entire process group.
async fn kill_process_tree(pid: u32) -> Result<()> {
    #[cfg(unix)]
    {
        // The child was launched in its own process group (pgid == pid).
        // A negative pid sends the signal to the whole group.
        let target = format!("-{}", pid);
        let output = Command::new("kill")
            .arg("-9")
            .arg(&target)
            .output()
            .await
            .context("spawn kill")?;
        if !output.status.success() {
            // Fallback to the leader itself.
            let _ = Command::new("kill")
                .arg("-9")
                .arg(pid.to_string())
                .output()
                .await;
        }
        Ok(())
    }
    #[cfg(not(unix))]
    {
        // Best-effort fallback: try taskkill on Windows.
        let _ = Command::new("taskkill")
            .args(["/F", "/T", "/PID", &pid.to_string()])
            .output()
            .await;
        Ok(())
    }
}
