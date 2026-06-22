//! Detection of an existing Erlang/OTP + Elixir runtime.
//!
//! The actual version probing shells out to `elixir --version` (which reports
//! *both* the running OTP release and the Elixir version on a single invocation),
//! falling back to `erl` when Elixir is absent. All of the parsing is factored
//! into pure functions so it can be unit-tested without a runtime installed.

use super::{MIN_ELIXIR, MIN_OTP_MAJOR};
use std::ffi::OsStr;
use tokio::process::Command;

/// A parsed Elixir semantic version.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ElixirVersion {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
}

impl ElixirVersion {
    /// True when this version is >= the `(major, minor)` floor.
    pub fn at_least(&self, floor: (u32, u32)) -> bool {
        (self.major, self.minor) >= floor
    }
}

impl std::fmt::Display for ElixirVersion {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

/// What we found (or didn't) for a given runtime probe.
#[derive(Debug, Clone, Default)]
pub struct Detected {
    /// Major OTP release (e.g. `27`), if a runtime was found.
    pub otp_major: Option<u32>,
    /// Elixir version, if found.
    pub elixir: Option<ElixirVersion>,
}

impl Detected {
    /// True when both Erlang and Elixir are present and meet the minimum
    /// versions the app requires.
    pub fn is_satisfactory(&self) -> bool {
        let otp_ok = self.otp_major.is_some_and(|v| v >= MIN_OTP_MAJOR);
        let elixir_ok = self.elixir.is_some_and(|v| v.at_least(MIN_ELIXIR));
        otp_ok && elixir_ok
    }

    /// Human-readable list of what is missing or too old, for the setup screen.
    pub fn shortfalls(&self) -> Vec<String> {
        let mut out = Vec::new();
        match self.otp_major {
            None => out.push("Erlang/OTP is not installed".to_string()),
            Some(v) if v < MIN_OTP_MAJOR => {
                out.push(format!("Erlang/OTP {v} is older than the required {MIN_OTP_MAJOR}"))
            }
            Some(_) => {}
        }
        match self.elixir {
            None => out.push("Elixir is not installed".to_string()),
            Some(v) if !v.at_least(MIN_ELIXIR) => out.push(format!(
                "Elixir {v} is older than the required {}.{}",
                MIN_ELIXIR.0, MIN_ELIXIR.1
            )),
            Some(_) => {}
        }
        out
    }
}

/// Parse the major OTP release out of an `erl`/`elixir --version` banner.
///
/// Matches the `Erlang/OTP 27 [erts-15.1.2] ...` line that both tools print.
pub fn parse_otp_major(output: &str) -> Option<u32> {
    let idx = output.find("Erlang/OTP")?;
    let rest = output[idx + "Erlang/OTP".len()..].trim_start();
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

/// Parse the Elixir version out of an `elixir --version` banner.
///
/// Matches the `Elixir 1.18.1 (compiled with Erlang/OTP 27)` line.
pub fn parse_elixir_version(output: &str) -> Option<ElixirVersion> {
    // Find a line that starts with "Elixir " so we don't accidentally pick up
    // the "compiled with Erlang/OTP" tail.
    let line = output
        .lines()
        .map(str::trim)
        .find(|l| l.starts_with("Elixir "))?;
    let token = line["Elixir ".len()..].split_whitespace().next()?;
    parse_semver(token)
}

fn parse_semver(token: &str) -> Option<ElixirVersion> {
    let mut parts = token.split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next()?.parse().ok()?;
    // Patch may be absent (e.g. "1.18") or carry a pre-release suffix.
    let patch = parts
        .next()
        .map(|p| p.trim_matches(|c: char| !c.is_ascii_digit()))
        .and_then(|p| p.parse().ok())
        .unwrap_or(0);
    Some(ElixirVersion {
        major,
        minor,
        patch,
    })
}

/// Probe a runtime by running `elixir --version` through the given command
/// prefix. `prefix` is the program plus any leading args (e.g. the bare
/// `["elixir"]` for a PATH lookup, or `["mise", "exec", "--", "elixir"]`).
///
/// Returns an empty [`Detected`] when the command can't be run at all.
pub async fn probe(program: impl AsRef<OsStr>, leading_args: &[&str]) -> Detected {
    let output = Command::new(program)
        .args(leading_args)
        .arg("--version")
        .output()
        .await;

    let Ok(output) = output else {
        return Detected::default();
    };
    if !output.status.success() {
        return Detected::default();
    }

    // `elixir --version` prints the OTP banner on stderr/stdout depending on
    // the platform; concatenate both so parsing is robust.
    let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
    text.push('\n');
    text.push_str(&String::from_utf8_lossy(&output.stderr));

    Detected {
        otp_major: parse_otp_major(&text),
        elixir: parse_elixir_version(&text),
    }
}

/// Detect an Elixir runtime available directly on the user's `PATH`.
pub async fn detect_on_path() -> Detected {
    probe("elixir", &[]).await
}

#[cfg(test)]
mod tests {
    use super::*;

    const ELIXIR_BANNER: &str = "Erlang/OTP 27 [erts-15.1.2] [source] [64-bit] [smp:10:10:10] [ds:10:10:10] [async-threads:1] [jit]\n\nElixir 1.18.1 (compiled with Erlang/OTP 27)\n";

    #[test]
    fn parses_otp_major_from_banner() {
        assert_eq!(parse_otp_major(ELIXIR_BANNER), Some(27));
        assert_eq!(parse_otp_major("Erlang/OTP 26 [erts-14.2]"), Some(26));
        assert_eq!(parse_otp_major("no erlang here"), None);
    }

    #[test]
    fn parses_elixir_version_from_banner() {
        assert_eq!(
            parse_elixir_version(ELIXIR_BANNER),
            Some(ElixirVersion {
                major: 1,
                minor: 18,
                patch: 1
            })
        );
    }

    #[test]
    fn parses_elixir_version_without_patch() {
        assert_eq!(
            parse_elixir_version("Elixir 1.15 (compiled with Erlang/OTP 26)"),
            Some(ElixirVersion {
                major: 1,
                minor: 15,
                patch: 0
            })
        );
    }

    #[test]
    fn parses_elixir_prerelease_patch() {
        // Pre-release suffixes should not break patch parsing.
        assert_eq!(
            parse_elixir_version("Elixir 1.19.0-rc.0 (compiled with Erlang/OTP 27)"),
            Some(ElixirVersion {
                major: 1,
                minor: 19,
                patch: 0
            })
        );
    }

    #[test]
    fn satisfactory_requires_both_runtimes() {
        let ok = Detected {
            otp_major: Some(27),
            elixir: Some(ElixirVersion {
                major: 1,
                minor: 18,
                patch: 1,
            }),
        };
        assert!(ok.is_satisfactory());
        assert!(ok.shortfalls().is_empty());

        let no_elixir = Detected {
            otp_major: Some(27),
            elixir: None,
        };
        assert!(!no_elixir.is_satisfactory());
        assert_eq!(no_elixir.shortfalls().len(), 1);

        let old = Detected {
            otp_major: Some(24),
            elixir: Some(ElixirVersion {
                major: 1,
                minor: 12,
                patch: 0,
            }),
        };
        assert!(!old.is_satisfactory());
        assert_eq!(old.shortfalls().len(), 2);
    }
}
