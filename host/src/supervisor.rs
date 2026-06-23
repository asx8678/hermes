use crate::beam::BeamProcess;
use anyhow::Result;
use std::path::Path;
use std::time::Duration;
use tokio::net::TcpStream;
use tokio::time::timeout;

/// Supervises a BEAM child process with periodic health checks.
pub struct BeamSupervisor {
    beam: BeamProcess,
    health_check_interval: Duration,
}

impl BeamSupervisor {
    /// Start the BEAM release from `cache_dir` on the given `port`.
    ///
    /// `capture_logs` is forwarded to [`BeamProcess::spawn`]: set it for TUI
    /// launches so BEAM logs go to a file instead of the terminal.
    pub async fn start(cache_dir: &Path, port: u16, capture_logs: bool) -> Result<BeamSupervisor> {
        let mut beam = BeamProcess::spawn(cache_dir, port, capture_logs).await?;
        beam.wait_for_port().await?;

        Ok(BeamSupervisor {
            beam,
            health_check_interval: Duration::from_secs(5),
        })
    }

    /// Return a reference to the managed BEAM process.
    pub fn beam(&self) -> &BeamProcess {
        &self.beam
    }

    /// Return the port the BEAM process is listening on.
    pub fn port(&self) -> u16 {
        self.beam.port()
    }

    /// Check whether the BEAM WebSocket endpoint is responsive.
    ///
    /// This performs a TCP connect to `127.0.0.1:<port>` with a short timeout.
    pub async fn health_check(&self) -> bool {
        let addr = format!("127.0.0.1:{}", self.beam.port());
        timeout(Duration::from_secs(2), TcpStream::connect(&addr))
            .await
            .is_ok_and(|r| r.is_ok())
    }

    /// Run health checks in a loop until the BEAM becomes unresponsive.
    ///
    /// Returns `Ok` when the BEAM stops responding, or `Err` if the check
    /// itself fails unexpectedly.
    pub async fn monitor_health(&self) -> Result<()> {
        loop {
            tokio::time::sleep(self.health_check_interval).await;
            if !self.health_check().await {
                return Ok(());
            }
        }
    }

    /// Gracefully shut down the BEAM process and verify cleanup.
    pub async fn shutdown(&mut self) -> Result<()> {
        self.beam.graceful_shutdown().await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::Rng;

    fn random_port() -> u16 {
        let mut rng = rand::thread_rng();
        rng.gen_range(10000..=60000)
    }

    fn temp_cache_root() -> tempfile::TempDir {
        tempfile::tempdir().expect("creating temp dir")
    }

    #[tokio::test]
    async fn health_check_true_for_running_beam() {
        let root = temp_cache_root();
        let cache_dir = BeamProcess::extract_to(&root).await.unwrap();
        let port = random_port();

        let supervisor = BeamSupervisor::start(&cache_dir, port, false).await.unwrap();
        assert!(supervisor.health_check().await);

        // Supervisor does not implement Drop-based shutdown, so call it
        // explicitly. Even if the assertion above failed, the test harness
        // will drop the supervisor and the child is marked `kill_on_drop`.
        let mut supervisor = supervisor;
        supervisor.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn health_check_false_after_shutdown() {
        let root = temp_cache_root();
        let cache_dir = BeamProcess::extract_to(&root).await.unwrap();
        let port = random_port();

        let mut supervisor = BeamSupervisor::start(&cache_dir, port, false).await.unwrap();
        supervisor.shutdown().await.unwrap();

        assert!(!supervisor.health_check().await);
    }
}
