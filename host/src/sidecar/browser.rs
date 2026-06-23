use crate::sidecar::protocol::{Message, Response};
use anyhow::{Context, Result};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::tungstenite::Message as WsMessage;

/// Entry point for `hermes-sidecar browser`.
///
/// Reads newline-delimited JSON requests from stdin and writes responses to
/// stdout. Manages a headless Chrome/Chromium instance via the Chrome DevTools
/// Protocol (CDP) over WebSocket.
pub async fn run() -> Result<()> {
    let stdin = tokio::io::stdin();
    let reader = BufReader::new(stdin);
    let mut lines = reader.lines();

    let (response_tx, mut response_rx) = mpsc::channel::<Message<Response>>(64);

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

    // Browser session state — lazy-initialized on first request.
    let session: Arc<Mutex<Option<BrowserSession>>> = Arc::new(Mutex::new(None));

    while let Some(line) = lines.next_line().await? {
        let request: Message<BrowserRequest> = match serde_json::from_str(&line) {
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

        let id = request.id;
        let tx = response_tx.clone();
        let session = session.clone();

        tokio::spawn(async move {
            let resp = handle_browser_request(request.body, session).await;
            let _ = tx.send(Message { id, body: resp }).await;
        });
    }

    // Clean up browser process on exit
    {
        let mut guard = session.lock().await;
        if let Some(mut s) = guard.take() {
            let _ = s.chrome.kill().await;
        }
    }

    let _ = writer_handle.await;
    Ok(())
}

/// Per-session browser state: the Chrome subprocess + CDP WebSocket.
struct BrowserSession {
    chrome: tokio::process::Child,
    ws: tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    target_id: String,
    msg_counter: u64,
}

#[derive(Deserialize, Debug)]
#[serde(tag = "action", rename_all = "snake_case")]
enum BrowserRequest {
    Navigate { url: String },
    Snapshot,
    Click { selector: String },
    Type { selector: String, text: String },
    Scroll { x: Option<i32>, y: Option<i32> },
    Back,
    Press { key: String },
    GetImages,
    Console,
    Cdp {
        method: String,
        params: serde_json::Value,
    },
    Dialog { dialog_action: String },
}

async fn handle_browser_request(
    req: BrowserRequest,
    session: Arc<Mutex<Option<BrowserSession>>>,
) -> Response {
    // Ensure browser is started
    {
        let mut guard = session.lock().await;
        if guard.is_none() {
            match start_browser().await {
                Ok(s) => *guard = Some(s),
                Err(e) => {
                    return Response::Error {
                        message: format!("failed to start browser: {}", e),
                    }
                }
            }
        }
    }

    match req {
        BrowserRequest::Navigate { url } => {
            let cdp_resp = cdp_call(&session, "Page.navigate", serde_json::json!({"url": url})).await;
            match cdp_resp {
                Ok(v) => Response::ExecuteResult {
                    stdout: format!("Navigated to: {}", url),
                    stderr: String::new(),
                    exit_code: 0,
                },
                Err(e) => Response::Error { message: e.to_string() },
            }
        }
        BrowserRequest::Snapshot => {
            let cdp_resp = cdp_call(&session, "DOM.getDocument", serde_json::json!({"depth": -1})).await;
            match cdp_resp {
                Ok(v) => {
                    let html = serde_json::to_string_pretty(&v).unwrap_or_default();
                    Response::ExecuteResult {
                        stdout: html,
                        stderr: String::new(),
                        exit_code: 0,
                    }
                }
                Err(e) => Response::Error { message: e.to_string() },
            }
        }
        BrowserRequest::Click { selector } => {
            let expr = format!(
                "document.querySelector('{}')?.click()",
                selector.replace('\'', "\\'")
            );
            let cdp_resp = cdp_call(&session, "Runtime.evaluate", serde_json::json!({"expression": expr})).await;
            match cdp_resp {
                Ok(_) => Response::ExecuteResult {
                    stdout: format!("Clicked: {}", selector),
                    stderr: String::new(),
                    exit_code: 0,
                },
                Err(e) => Response::Error { message: e.to_string() },
            }
        }
        BrowserRequest::Type { selector, text } => {
            let expr = format!(
                "(function(){{var el=document.querySelector('{}');if(el){{el.focus();el.value='{}';el.dispatchEvent(new Event('input',{{bubbles:true}}));}}}})()",
                selector.replace('\'', "\\'"),
                text.replace('\'', "\\'")
            );
            let cdp_resp = cdp_call(&session, "Runtime.evaluate", serde_json::json!({"expression": expr})).await;
            match cdp_resp {
                Ok(_) => Response::ExecuteResult {
                    stdout: format!("Typed into: {}", selector),
                    stderr: String::new(),
                    exit_code: 0,
                },
                Err(e) => Response::Error { message: e.to_string() },
            }
        }
        BrowserRequest::Scroll { x, y } => {
            let sx = x.unwrap_or(0);
            let sy = y.unwrap_or(0);
            let expr = format!("window.scroll({}, {})", sx, sy);
            let cdp_resp = cdp_call(&session, "Runtime.evaluate", serde_json::json!({"expression": expr})).await;
            match cdp_resp {
                Ok(_) => Response::ExecuteResult {
                    stdout: format!("Scrolled to ({}, {})", sx, sy),
                    stderr: String::new(),
                    exit_code: 0,
                },
                Err(e) => Response::Error { message: e.to_string() },
            }
        }
        BrowserRequest::Back => {
            let cdp_resp = cdp_call(&session, "Page.navigate", serde_json::json!({"url": "javascript:history.back()"})).await;
            match cdp_resp {
                Ok(_) => Response::ExecuteResult {
                    stdout: "Navigated back".to_string(),
                    stderr: String::new(),
                    exit_code: 0,
                },
                Err(e) => Response::Error { message: e.to_string() },
            }
        }
        BrowserRequest::Press { key } => {
            let expr = format!(
                "document.dispatchEvent(new KeyboardEvent('keydown',{{key:'{}'}}))",
                key.replace('\'', "\\'")
            );
            let cdp_resp = cdp_call(&session, "Runtime.evaluate", serde_json::json!({"expression": expr})).await;
            match cdp_resp {
                Ok(_) => Response::ExecuteResult {
                    stdout: format!("Pressed: {}", key),
                    stderr: String::new(),
                    exit_code: 0,
                },
                Err(e) => Response::Error { message: e.to_string() },
            }
        }
        BrowserRequest::GetImages => {
            let expr = "Array.from(document.querySelectorAll('img')).map(i=>({src:i.src,alt:i.alt,width:i.naturalWidth,height:i.naturalHeight}))";
            let cdp_resp = cdp_call(&session, "Runtime.evaluate", serde_json::json!({"expression": expr, "returnByValue": true})).await;
            match cdp_resp {
                Ok(v) => {
                    let images = serde_json::to_string_pretty(&v).unwrap_or_default();
                    Response::ExecuteResult {
                        stdout: images,
                        stderr: String::new(),
                        exit_code: 0,
                    }
                }
                Err(e) => Response::Error { message: e.to_string() },
            }
        }
        BrowserRequest::Console => {
            let cdp_resp = cdp_call(&session, "Runtime.evaluate", serde_json::json!({"expression": "console.log"})).await;
            match cdp_resp {
                Ok(v) => {
                    let logs = serde_json::to_string_pretty(&v).unwrap_or_default();
                    Response::ExecuteResult {
                        stdout: logs,
                        stderr: String::new(),
                        exit_code: 0,
                    }
                }
                Err(e) => Response::Error { message: e.to_string() },
            }
        }
        BrowserRequest::Cdp { method, params } => {
            let cdp_resp = cdp_call(&session, &method, params).await;
            match cdp_resp {
                Ok(v) => {
                    let result = serde_json::to_string_pretty(&v).unwrap_or_default();
                    Response::ExecuteResult {
                        stdout: result,
                        stderr: String::new(),
                        exit_code: 0,
                    }
                }
                Err(e) => Response::Error { message: e.to_string() },
            }
        }
        BrowserRequest::Dialog { dialog_action } => {
            let cdp_method = "Page.handleJavaScriptDialog";
            let params = serde_json::json!({"accept": dialog_action == "accept"});
            let cdp_resp = cdp_call(&session, cdp_method, params).await;
            match cdp_resp {
                Ok(_) => Response::ExecuteResult {
                    stdout: format!("Dialog: {}", dialog_action),
                    stderr: String::new(),
                    exit_code: 0,
                },
                Err(e) => Response::Error { message: e.to_string() },
            }
        }
    }
}

async fn start_browser() -> Result<BrowserSession> {
    // Find Chrome/Chromium binary
    let chrome_path = find_chrome()?;

    // Pick a random free port for CDP
    let port = pick_free_port();

    // Spawn Chrome headless with remote debugging
    let mut chrome = tokio::process::Command::new(&chrome_path)
        .args([
            "--headless",
            "--disable-gpu",
            "--no-sandbox",
            "--disable-dev-shm-usage",
            &format!("--remote-debugging-port={}", port),
            "about:blank",
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .context("failed to spawn Chrome")?;

    // Wait for CDP to be ready (poll the JSON endpoint)
    let cdp_url = format!("ws://127.0.0.1:{}/devtools/page/1", port);
    let ws_url = format!("http://127.0.0.1:{}/json", port);

    // Poll for readiness
    let mut ready = false;
    for _ in 0..30 {
        if let Ok(resp) = reqwest::get(&ws_url).await {
            if resp.status().is_success() {
                ready = true;
                break;
            }
        }
        tokio::time::sleep(tokio::time::Duration::from_millis(200)).await;
    }

    if !ready {
        let _ = chrome.kill().await;
        anyhow::bail!("Chrome CDP did not become ready on port {}", port);
    }

    // Connect WebSocket
    let (ws, _) = tokio_tungstenite::connect_async(&cdp_url)
        .await
        .context("failed to connect to CDP WebSocket")?;

    Ok(BrowserSession {
        chrome,
        ws,
        target_id: "1".to_string(),
        msg_counter: 0,
    })
}

async fn cdp_call(
    session: &Arc<Mutex<Option<BrowserSession>>>,
    method: &str,
    params: serde_json::Value,
) -> Result<serde_json::Value> {
    let mut guard = session.lock().await;
    let session = guard.as_mut().context("browser not started")?;

    session.msg_counter += 1;
    let id = session.msg_counter;

    let msg = serde_json::json!({
        "id": id,
        "method": method,
        "params": params,
    });

    let text = serde_json::to_string(&msg)?;
    session.ws.send(WsMessage::Text(text)).await?;

    // Read response (skip events until we get our id)
    loop {
        match session.ws.next().await {
            Some(Ok(WsMessage::Text(t))) => {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&t) {
                    if v.get("id").and_then(|i| i.as_u64()) == Some(id) {
                        if let Some(result) = v.get("result") {
                            return Ok(result.clone());
                        }
                        if let Some(error) = v.get("error") {
                            let msg = error
                                .get("message")
                                .and_then(|m| m.as_str())
                                .unwrap_or("unknown CDP error");
                            anyhow::bail!("CDP error: {}", msg);
                        }
                    }
                }
            }
            Some(Ok(WsMessage::Ping(p))) => {
                session.ws.send(WsMessage::Pong(p)).await?;
            }
            Some(Ok(_)) => continue,
            Some(Err(e)) => anyhow::bail!("CDP WebSocket error: {}", e),
            None => anyhow::bail!("CDP WebSocket closed"),
        }
    }
}

fn find_chrome() -> Result<String> {
    let candidates = if cfg!(target_os = "macos") {
        vec![
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
        ]
    } else if cfg!(target_os = "linux") {
        vec![
            "google-chrome",
            "google-chrome-stable",
            "chromium",
            "chromium-browser",
            "brave-browser",
            "microsoft-edge",
        ]
    } else {
        vec![
            "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
            "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
        ]
    };

    for c in &candidates {
        if std::path::Path::new(c).exists() {
            return Ok(c.to_string());
        }
    }

    // Try `which`
    for name in &["google-chrome", "chromium", "chrome"] {
        if let Ok(output) = std::process::Command::new("which").arg(name).output() {
            if output.status.success() {
                let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
                if !path.is_empty() {
                    return Ok(path);
                }
            }
        }
    }

    anyhow::bail!("no Chrome/Chromium binary found")
}

fn pick_free_port() -> u16 {
    use std::net::TcpListener;
    TcpListener::bind("127.0.0.1:0")
        .and_then(|listener| listener.local_addr().map(|a| a.port()))
        .unwrap_or(9222)
}

async fn write_message(
    stdout: &mut tokio::io::Stdout,
    msg: Message<Response>,
) -> Result<()> {
    let json = serde_json::to_string(&msg)?;
    stdout.write_all(json.as_bytes()).await?;
    stdout.write_all(b"\n").await?;
    stdout.flush().await?;
    Ok(())
}
