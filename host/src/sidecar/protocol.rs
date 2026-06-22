use serde::{Deserialize, Serialize};

/// A generic JSON-RPC-like envelope over newline-delimited stdio.
///
/// The `id` correlates a response with its request. The body is flattened
/// into the same object so the wire format stays compact.
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Message<T> {
    pub id: u64,
    #[serde(flatten)]
    pub body: T,
}

/// Sidecar request body.
#[derive(Serialize, Deserialize, Debug)]
#[serde(tag = "method", rename_all = "snake_case")]
pub enum Request {
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

/// Snapshot of a tracked sidecar process.
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ProcessInfo {
    pub pid: u32,
    pub command: String,
    pub status: String,
}

/// Sidecar response body.
#[derive(Serialize, Deserialize, Debug)]
#[serde(tag = "method", rename_all = "snake_case")]
pub enum Response {
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
