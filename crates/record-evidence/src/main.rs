//! `record-evidence` CLI binary.
//!
//! Reads a `luggage install --json-report` file, combines it with
//! CI-runner-supplied metadata, and writes a containers-db `TestEntry`
//! row as pretty JSON to stdout.

use std::fs;
use std::io;
use std::io::Write as _;
use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;
use luggage::InstallReport;
use record_evidence::{RecorderError, RecorderInputs, build_test_entry};

/// Combine a luggage install report with CI metadata into a
/// containers-db `TestEntry` row.
#[derive(Parser, Debug)]
#[command(name = "record-evidence", version, about, long_about = None)]
struct Cli {
    /// Path to the JSON file luggage wrote via `--json-report`.
    #[arg(long, value_name = "PATH")]
    luggage_report: PathBuf,

    /// Pull-spec for the base image exercised.
    #[arg(long, value_name = "REF")]
    image_ref: String,

    /// Content-addressed digest of `--image-ref` (must match
    /// `sha256:<64 hex chars>`).
    #[arg(long, value_name = "SHA256")]
    image_digest: String,

    /// CI run URL.
    #[arg(long, value_name = "URL")]
    ci_run: Option<String>,

    /// Distro id.
    #[arg(long)]
    os: String,

    /// Distro version (e.g. `12`, `3.21`).
    #[arg(long)]
    os_version: Option<String>,

    /// CPU architecture.
    #[arg(long)]
    arch: String,
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("record-evidence: {e}");
            // 2 reserved for input-validation problems (bad digest,
            // empty image_ref) so CI can branch on it. Everything else
            // exits 1.
            match e {
                RecorderError::InvalidImageDigest(_) | RecorderError::EmptyImageRef => {
                    ExitCode::from(2)
                }
                _ => ExitCode::from(1),
            }
        }
    }
}

fn run() -> Result<(), RecorderError> {
    let cli = Cli::parse();
    let report = read_report(&cli.luggage_report)?;

    let inputs = RecorderInputs {
        luggage_report: report,
        image_ref: cli.image_ref,
        image_digest: cli.image_digest,
        ci_run: cli.ci_run,
        os: cli.os,
        os_version: cli.os_version,
        arch: cli.arch,
    };
    let entry = build_test_entry(inputs)?;

    let stdout = io::stdout();
    let mut handle = stdout.lock();
    serde_json::to_writer_pretty(&mut handle, &entry)?;
    handle.write_all(b"\n").map_err(|e| RecorderError::LuggageReport {
        path: "<stdout>".into(),
        message: e.to_string(),
    })?;
    Ok(())
}

fn read_report(path: &PathBuf) -> Result<InstallReport, RecorderError> {
    let body = fs::read_to_string(path).map_err(|e| RecorderError::LuggageReport {
        path: path.display().to_string(),
        message: e.to_string(),
    })?;
    serde_json::from_str(&body).map_err(|e| RecorderError::LuggageReport {
        path: path.display().to_string(),
        message: e.to_string(),
    })
}
