use crate::sidecar::protocol::Message;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::io::Write;
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;
use tokio::process::{Child, Command};
use tokio::time::{sleep, Duration};

/// Default execution limits.
const DEFAULT_TIMEOUT_SECS: u64 = 30;
const DEFAULT_MEMORY_LIMIT_MB: u64 = 256;
const MAX_STDOUT_BYTES: usize = 50_000;
const MAX_STDERR_BYTES: usize = 10_000;

/// Result of running sandboxed code.
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ExecutionResult {
    pub stdout: String,
    pub stderr: String,
    pub exit_code: i32,
}

/// Configuration for the code execution sandbox.
#[derive(Debug, Clone)]
pub struct CodeSandbox {
    pub timeout_secs: u64,
    pub memory_limit_mb: u64,
}

impl Default for CodeSandbox {
    fn default() -> Self {
        Self {
            timeout_secs: DEFAULT_TIMEOUT_SECS,
            memory_limit_mb: DEFAULT_MEMORY_LIMIT_MB,
        }
    }
}

/// JSON-RPC request body for the code-execution sidecar.
#[derive(Serialize, Deserialize, Debug)]
#[serde(tag = "method", rename_all = "snake_case")]
pub enum CodeRequest {
    Execute {
        code: String,
        language: String,
        #[serde(default = "default_timeout")]
        timeout_secs: u64,
        #[serde(default = "default_memory")]
        memory_limit_mb: u64,
    },
    ExecuteWithTools {
        code: String,
        allowed_tools: Vec<String>,
        #[serde(default = "default_timeout")]
        timeout_secs: u64,
        #[serde(default = "default_memory")]
        memory_limit_mb: u64,
    },
}

fn default_timeout() -> u64 {
    DEFAULT_TIMEOUT_SECS
}

fn default_memory() -> u64 {
    DEFAULT_MEMORY_LIMIT_MB
}

/// JSON-RPC response body for the code-execution sidecar.
#[derive(Serialize, Deserialize, Debug)]
#[serde(tag = "method", rename_all = "snake_case")]
pub enum CodeResponse {
    ExecuteResult {
        stdout: String,
        stderr: String,
        exit_code: i32,
    },
    Error {
        message: String,
    },
}

/// Entry point for `hermes-sidecar code-execution`.
///
/// Reads newline-delimited JSON-RPC requests from stdin and writes responses to
/// stdout. Each request runs in a separate OS subprocess so a crash or runaway
/// script cannot affect the BEAM.
pub async fn run() -> Result<()> {
    let stdin = tokio::io::stdin();
    let reader = BufReader::new(stdin);
    let mut lines = reader.lines();

    let (response_tx, mut response_rx) = tokio::sync::mpsc::channel::<Message<CodeResponse>>(64);

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

    while let Some(line) = lines.next_line().await? {
        let request: Message<CodeRequest> = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                let _ = response_tx
                    .send(Message {
                        id: 0,
                        body: CodeResponse::Error {
                            message: format!("parse error: {}", e),
                        },
                    })
                    .await;
                continue;
            }
        };

        let tx = response_tx.clone();
        tokio::spawn(async move {
            let response = handle_request(request.body).await;
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

async fn write_message(stdout: &mut tokio::io::Stdout, msg: Message<CodeResponse>) -> Result<()> {
    let line = serde_json::to_string(&msg).context("serialize response")?;
    stdout.write_all(line.as_bytes()).await?;
    stdout.write_all(b"\n").await?;
    stdout.flush().await?;
    Ok(())
}

async fn handle_request(req: CodeRequest) -> CodeResponse {
    match req {
        CodeRequest::Execute {
            code,
            language,
            timeout_secs,
            memory_limit_mb,
        } => {
            let sandbox = CodeSandbox {
                timeout_secs,
                memory_limit_mb,
            };
            match sandbox.execute(&code, &language).await {
                Ok(result) => CodeResponse::ExecuteResult {
                    stdout: result.stdout,
                    stderr: result.stderr,
                    exit_code: result.exit_code,
                },
                Err(e) => CodeResponse::Error {
                    message: format!("execution failed: {}", e),
                },
            }
        }
        CodeRequest::ExecuteWithTools {
            code,
            allowed_tools,
            timeout_secs,
            memory_limit_mb,
        } => {
            let sandbox = CodeSandbox {
                timeout_secs,
                memory_limit_mb,
            };
            match sandbox.execute_with_tools(&code, &allowed_tools).await {
                Ok(result) => CodeResponse::ExecuteResult {
                    stdout: result.stdout,
                    stderr: result.stderr,
                    exit_code: result.exit_code,
                },
                Err(e) => CodeResponse::Error {
                    message: format!("execution with tools failed: {}", e),
                },
            }
        }
    }
}

impl CodeSandbox {
    /// Execute a code snippet in a subprocess with timeout and memory limits.
    ///
    /// Supported languages: `python` and `elixir`.
    pub async fn execute(&self, code: &str, language: &str) -> Result<ExecutionResult> {
        let (interpreter, extension) = interpreter_for(language)
            .with_context(|| format!("unsupported language: {}", language))?;

        let tmp = tempfile::Builder::new()
            .prefix("hermes_code_")
            .tempdir()
            .context("create sandbox temp dir")?;

        let script_path = tmp.path().join(format!("main.{}", extension));
        write_script(&script_path, code).context("write script file")?;

        let mut child =
            spawn_interpreter(&interpreter, &script_path, tmp.path(), self.memory_limit_mb)
                .context("spawn interpreter")?;

        run_child(&mut child, self.timeout_secs).await
    }

    /// Execute Python code with a generated `hermes_tools` module.
    ///
    /// Tools named in `allowed_tools` are injected as stubs that call back to
    /// this process over a loopback TCP socket. The sidecar returns mock
    /// results so the script can exercise tool calls without a full Hermes core.
    pub async fn execute_with_tools(
        &self,
        code: &str,
        allowed_tools: &[String],
    ) -> Result<ExecutionResult> {
        let tmp = tempfile::Builder::new()
            .prefix("hermes_code_tools_")
            .tempdir()
            .context("create sandbox temp dir")?;

        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .context("bind RPC listener")?;
        let port = listener.local_addr()?.port();
        let rpc_endpoint = format!("tcp://127.0.0.1:{}", port);

        let module_path = tmp.path().join("hermes_tools.py");
        let allowed_set: HashSet<String> = allowed_tools.iter().cloned().collect();
        let module_source = generate_hermes_tools_module(&allowed_set, &rpc_endpoint);
        write_script(&module_path, &module_source).context("write hermes_tools module")?;

        let script_path = tmp.path().join("main.py");
        let wrapped = format!("from hermes_tools import *\n{}", code);
        write_script(&script_path, &wrapped).context("write user script")?;

        let mut child =
            spawn_interpreter("python3", &script_path, tmp.path(), self.memory_limit_mb)
                .context("spawn interpreter")?;

        let stdout = child.stdout.take().expect("stdout piped");
        let stderr = child.stderr.take().expect("stderr piped");
        let stdout_fut = read_pipe(stdout, MAX_STDOUT_BYTES);
        let stderr_fut = read_pipe(stderr, MAX_STDERR_BYTES);

        let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel();
        let allowed = allowed_set.clone();
        let rpc_task = tokio::spawn(run_rpc_server(listener, allowed, shutdown_rx));

        let timeout = sleep(Duration::from_secs(self.timeout_secs));
        tokio::pin!(timeout);

        let result = tokio::select! {
            _ = &mut timeout => {
                if let Some(pid) = child.id() {
                    let _ = kill_process_tree(pid).await;
                }
                let _ = child.wait().await;
                let stdout = stdout_fut.await.unwrap_or_default();
                let stderr = format!(
                    "{}\nkilled after {}s timeout",
                    stderr_fut.await.unwrap_or_default(),
                    self.timeout_secs
                );
                ExecutionResult { stdout, stderr, exit_code: -1 }
            }
            status = child.wait() => {
                let stdout = stdout_fut.await.unwrap_or_default();
                let stderr = stderr_fut.await.unwrap_or_default();
                let exit_code = status.ok().and_then(|s| s.code()).unwrap_or(-1);
                ExecutionResult { stdout, stderr, exit_code }
            }
        };

        let _ = shutdown_tx.send(());
        let _ = rpc_task.await;
        Ok(result)
    }
}

fn interpreter_for(language: &str) -> Result<(String, String)> {
    match language.to_lowercase().as_str() {
        "python" => Ok(("python3".to_string(), "py".to_string())),
        "elixir" => Ok(("elixir".to_string(), "exs".to_string())),
        _ => Err(anyhow::anyhow!("unsupported language")),
    }
}

fn write_script(path: &std::path::Path, code: &str) -> Result<()> {
    let mut file = std::fs::File::create(path).context("create script")?;
    file.write_all(code.as_bytes()).context("write script")?;
    Ok(())
}

/// # Security limitations
///
/// This sandbox uses `RLIMIT_AS` (Linux) / `RLIMIT_DATA` (macOS) for memory
/// isolation. These are not robust jails: a non-privileged process can raise
/// its own soft limit on many systems. There is no seccomp, namespace, or
/// chroot isolation. This is a best-effort containment for development use;
/// production deployments executing untrusted code should add seccomp/chroot.
fn spawn_interpreter(
    interpreter: &str,
    script: &std::path::Path,
    cwd: &std::path::Path,
    memory_limit_mb: u64,
) -> Result<Child> {
    use std::process::Command as StdCommand;

    let mut std_cmd = StdCommand::new(interpreter);
    std_cmd
        .arg(script)
        .current_dir(cwd)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    // Isolate the child environment to the minimum required for the interpreter.
    std_cmd.env_clear();
    for key in [
        "PATH", "HOME", "USER", "LANG", "LC_ALL", "TMPDIR", "TEMP", "TMP", "SHELL",
    ] {
        if let Ok(value) = std::env::var(key) {
            std_cmd.env(key, value);
        }
    }

    #[cfg(unix)]
    {
        std::os::unix::process::CommandExt::process_group(&mut std_cmd, 0);

        let limit_bytes = memory_limit_mb * 1024 * 1024;
        unsafe {
            std::os::unix::process::CommandExt::pre_exec(&mut std_cmd, move || {
                #[cfg(target_os = "linux")]
                {
                    let lim = libc::rlimit {
                        rlim_cur: limit_bytes,
                        rlim_max: limit_bytes,
                    };
                    let _ = libc::setrlimit(libc::RLIMIT_AS, &lim);
                }
                #[cfg(target_os = "macos")]
                {
                    let lim = libc::rlimit {
                        rlim_cur: limit_bytes,
                        rlim_max: limit_bytes,
                    };
                    let _ = libc::setrlimit(libc::RLIMIT_DATA, &lim);
                }
                Ok(())
            });
        }
    }

    let mut cmd: Command = std_cmd.into();
    let child = cmd
        .spawn()
        .with_context(|| format!("failed to spawn {}", interpreter))?;
    Ok(child)
}

async fn run_child(child: &mut Child, timeout_secs: u64) -> Result<ExecutionResult> {
    let stdout = child.stdout.take().context("stdout piped")?;
    let stderr = child.stderr.take().context("stderr piped")?;

    let stdout_fut = read_pipe(stdout, MAX_STDOUT_BYTES);
    let stderr_fut = read_pipe(stderr, MAX_STDERR_BYTES);

    let timeout = sleep(Duration::from_secs(timeout_secs));
    tokio::pin!(timeout);

    let result = tokio::select! {
        _ = &mut timeout => {
            if let Some(pid) = child.id() {
                let _ = kill_process_tree(pid).await;
            }
            let _ = child.wait().await;
            let stdout = stdout_fut.await.unwrap_or_default();
            let stderr = format!(
                "{}\nkilled after {}s timeout",
                stderr_fut.await.unwrap_or_default(),
                timeout_secs
            );
            ExecutionResult { stdout, stderr, exit_code: -1 }
        }
        status = child.wait() => {
            let stdout = stdout_fut.await.unwrap_or_default();
            let stderr = stderr_fut.await.unwrap_or_default();
            let exit_code = status.ok().and_then(|s| s.code()).unwrap_or(-1);
            ExecutionResult { stdout, stderr, exit_code }
        }
    };

    Ok(result)
}

async fn read_pipe<R>(mut reader: R, max_bytes: usize) -> Result<String>
where
    R: AsyncRead + Unpin,
{
    let mut buf = Vec::new();
    reader.read_to_end(&mut buf).await?;
    let text = String::from_utf8_lossy(&buf).to_string();
    Ok(truncate_bytes(&text, max_bytes))
}

fn truncate_bytes(s: &str, max_bytes: usize) -> String {
    if s.len() <= max_bytes {
        s.to_string()
    } else {
        let mut end = max_bytes;
        while end > 0 && !s.is_char_boundary(end) {
            end -= 1;
        }
        format!("{}\n[truncated]", &s[..end])
    }
}

async fn kill_process_tree(pid: u32) -> Result<()> {
    #[cfg(unix)]
    {
        let target = format!("-{}", pid);
        let output = Command::new("kill")
            .arg("-9")
            .arg(&target)
            .output()
            .await
            .context("spawn kill")?;
        if !output.status.success() {
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
        let _ = Command::new("taskkill")
            .args(["/F", "/T", "/PID", &pid.to_string()])
            .output()
            .await;
        Ok(())
    }
}

fn generate_hermes_tools_module(allowed_tools: &HashSet<String>, endpoint: &str) -> String {
    let mut stubs = String::new();
    stubs.push_str("\"\"\"Auto-generated Hermes tools RPC stubs.\"\"\"\n");
    stubs.push_str("import json, os, socket, threading\n\n");
    stubs.push_str(&format!("_RPC_ENDPOINT = {:?}\n", endpoint));
    stubs.push_str("_sock = None\n");
    stubs.push_str("_lock = threading.Lock()\n\n");
    stubs.push_str("def _connect():\n");
    stubs.push_str("    global _sock\n");
    stubs.push_str("    if _sock is None:\n");
    stubs.push_str("        if _RPC_ENDPOINT.startswith('tcp://'):\n");
    stubs.push_str("            host, _, port = _RPC_ENDPOINT[len('tcp://'):].rpartition(':')\n");
    stubs.push_str("            _sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)\n");
    stubs.push_str("            _sock.connect((host or '127.0.0.1', int(port)))\n");
    stubs.push_str("        else:\n");
    stubs.push_str("            _sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n");
    stubs.push_str("            _sock.connect(_RPC_ENDPOINT)\n");
    stubs.push_str("    return _sock\n\n");
    stubs.push_str("def _call(tool, args):\n");
    stubs.push_str("    req = json.dumps({'tool': tool, 'args': args}) + '\\n'\n");
    stubs.push_str("    with _lock:\n");
    stubs.push_str("        sock = _connect()\n");
    stubs.push_str("        sock.sendall(req.encode())\n");
    stubs.push_str("        buf = b''\n");
    stubs.push_str("        while True:\n");
    stubs.push_str("            chunk = sock.recv(65536)\n");
    stubs.push_str("            if not chunk:\n");
    stubs.push_str("                raise RuntimeError('Hermes tool server disconnected')\n");
    stubs.push_str("            buf += chunk\n");
    stubs.push_str("            if buf.endswith(b'\\n'):\n");
    stubs.push_str("                break\n");
    stubs.push_str("    return json.loads(buf.decode().strip())\n\n");

    let tool_signatures: [(&str, &str); 7] = [
        ("web_search", "query, limit=5"),
        ("web_extract", "urls"),
        ("read_file", "path, offset=1, limit=500"),
        ("write_file", "path, content, cross_profile=False"),
        (
            "search_files",
            "pattern, target='content', path='.', file_glob=None, limit=50, offset=0, output_mode='content', context=0",
        ),
        (
            "patch",
            "path=None, old_string=None, new_string=None, replace_all=False, mode='replace', patch=None, cross_profile=False",
        ),
        ("terminal", "command, timeout=None, workdir=None"),
    ];

    let mut exports = Vec::new();
    for (name, sig) in &tool_signatures {
        if allowed_tools.contains(*name) {
            exports.push(*name);
            stubs.push_str(&format!(
                "def {}({}):\n    return _call({:?}, locals())\n\n",
                name, sig, name
            ));
        }
    }

    if !exports.is_empty() {
        stubs.push_str(&format!("__all__ = {:?}\n", exports));
    }

    stubs
}

async fn run_rpc_server(
    listener: TcpListener,
    allowed_tools: HashSet<String>,
    mut shutdown: tokio::sync::oneshot::Receiver<()>,
) {
    loop {
        tokio::select! {
            _ = &mut shutdown => break,
            res = listener.accept() => {
                match res {
                    Ok((stream, _)) => {
                        let allowed = allowed_tools.clone();
                        tokio::spawn(handle_rpc_connection(stream, allowed));
                    }
                    Err(e) => {
                        eprintln!("RPC accept error: {}", e);
                        break;
                    }
                }
            }
        }
    }
}

async fn handle_rpc_connection(stream: tokio::net::TcpStream, allowed_tools: HashSet<String>) {
    let (read_half, mut write_half) = stream.into_split();
    let mut lines = BufReader::new(read_half).lines();

    while let Ok(Some(line)) = lines.next_line().await {
        let response = match serde_json::from_str::<serde_json::Value>(&line) {
            Ok(value) => {
                let tool = value.get("tool").and_then(|v| v.as_str()).unwrap_or("");
                let args = value
                    .get("args")
                    .cloned()
                    .unwrap_or(serde_json::Value::Null);
                if allowed_tools.contains(tool) {
                    serde_json::json!({
                        "ok": true,
                        "tool": tool,
                        "args": args,
                    })
                } else {
                    serde_json::json!({
                        "error": format!("tool {} is not allowed in this sandbox", tool),
                    })
                }
            }
            Err(e) => serde_json::json!({"error": format!("invalid JSON: {}", e)}),
        };

        if let Ok(payload) = serde_json::to_string(&response) {
            let _ = write_half.write_all(payload.as_bytes()).await;
            let _ = write_half.write_all(b"\n").await;
            let _ = write_half.flush().await;
        }
    }
}
