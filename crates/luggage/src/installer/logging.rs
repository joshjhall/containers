//! Per-feature logging that mirrors `lib/base/logging.sh`.
//!
//! Each invocation of `luggage install` opens a per-feature log file at
//! `<log_dir>/<tool>-<version>.log` and emits records in the same shape
//! the bash feature scripts produce, so downstream tools (notably
//! `check-build-logs.sh`) keep working unchanged during the migration:
//!
//! ```text
//! [HH:MM:SS] FEATURE START: <tool> <version>
//! [HH:MM:SS] COMMAND #N: <description>
//! Executing: <argv>
//! ────────────────────
//! <stdout/stderr>
//! ────────────────────
//! Exit code: N (Duration: Xs)
//! [HH:MM:SS] FEATURE END
//! ```
//!
//! Each line is also forwarded via `tracing::info!` so `--verbose` users
//! see the same timeline on stderr.

use std::fs::{File, OpenOptions, create_dir_all};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use tracing::info;

use crate::error::{LuggageError, Result};

/// Feature-scoped logger; one per `luggage install` invocation.
pub struct FeatureLogger {
    file: Mutex<File>,
    path: PathBuf,
    step: AtomicUsize,
    started: Instant,
}

impl FeatureLogger {
    /// Create a logger writing to `<log_dir>/<tool>-<version>.log`.
    ///
    /// # Errors
    ///
    /// - [`LuggageError::Io`] when `log_dir` cannot be created or the log
    ///   file cannot be opened for append.
    pub fn open(log_dir: &Path, tool: &str, version: &str) -> Result<Self> {
        create_dir_all(log_dir)
            .map_err(|e| LuggageError::Io { path: log_dir.to_owned(), source: e })?;
        let path = log_dir.join(format!("{tool}-{version}.log"));
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .map_err(|e| LuggageError::Io { path: path.clone(), source: e })?;
        Ok(Self {
            file: Mutex::new(file),
            path,
            step: AtomicUsize::new(0),
            started: Instant::now(),
        })
    }

    /// Path to the underlying log file.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Emit a `FEATURE START` banner.
    pub fn feature_start(&self, tool: &str, version: &str) {
        let line = format!("[{}] FEATURE START: {tool} {version}", clock());
        info!("{line}");
        self.write_line(&line);
    }

    /// Emit a numbered `COMMAND #N: <description>` banner.
    ///
    /// Increments the internal step counter; subsequent calls get the next
    /// number.
    pub fn step(&self, description: &str) {
        let n = self.step.fetch_add(1, Ordering::Relaxed) + 1;
        let line = format!("[{}] COMMAND #{n}: {description}", clock());
        info!("{line}");
        self.write_line(&line);
    }

    /// Emit a free-form message in the bash style.
    pub fn message(&self, msg: &str) {
        info!("{msg}");
        self.write_line(msg);
    }

    /// Emit a `FEATURE END` banner with elapsed time.
    pub fn feature_end(&self) {
        let elapsed = self.started.elapsed();
        let line = format!("[{}] FEATURE END (duration: {:.2}s)", clock(), elapsed.as_secs_f64());
        info!("{line}");
        self.write_line(&line);
    }

    fn write_line(&self, line: &str) {
        if let Ok(mut f) = self.file.lock() {
            let _: io::Result<()> = (|| {
                f.write_all(line.as_bytes())?;
                f.write_all(b"\n")?;
                Ok(())
            })();
        }
    }
}

/// Format current wall-clock time as `HH:MM:SS` (UTC).
fn clock() -> String {
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
    let h = (secs / 3600) % 24;
    let m = (secs / 60) % 60;
    let s = secs % 60;
    format!("{h:02}:{m:02}:{s:02}")
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::fs;

    use tempfile::tempdir;

    #[test]
    fn open_creates_log_file() {
        let dir = tempdir().unwrap();
        let logger = FeatureLogger::open(dir.path(), "rust", "1.95.0").unwrap();
        assert!(logger.path().exists());
        assert!(logger.path().to_string_lossy().ends_with("rust-1.95.0.log"));
    }

    #[test]
    fn step_counter_increments_per_call() {
        let dir = tempdir().unwrap();
        let logger = FeatureLogger::open(dir.path(), "rust", "1.95.0").unwrap();
        logger.feature_start("rust", "1.95.0");
        logger.step("first");
        logger.step("second");
        logger.feature_end();
        let body = fs::read_to_string(logger.path()).unwrap();
        assert!(body.contains("FEATURE START: rust 1.95.0"));
        assert!(body.contains("COMMAND #1: first"));
        assert!(body.contains("COMMAND #2: second"));
        assert!(body.contains("FEATURE END"));
    }

    #[test]
    fn message_emits_verbatim_line() {
        let dir = tempdir().unwrap();
        let logger = FeatureLogger::open(dir.path(), "x", "0").unwrap();
        logger.message("hello");
        let body = fs::read_to_string(logger.path()).unwrap();
        assert!(body.contains("hello"));
    }

    #[test]
    fn clock_returns_eight_chars() {
        let s = clock();
        assert_eq!(s.len(), 8);
        assert_eq!(s.chars().filter(|&c| c == ':').count(), 2);
    }
}
