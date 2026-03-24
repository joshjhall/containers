//! Stibbons: Host orchestrator for the containers build system.

use clap::Parser;

/// Stibbons - Container build system orchestrator.
///
/// Scaffolds devcontainer configurations and manages container builds.
/// (Successor to igor, rewritten in Rust.)
#[derive(Parser, Debug)]
#[command(name = "stibbons", version, about, long_about = None)]
struct Cli {
    /// Enable verbose output.
    #[arg(short, long)]
    verbose: bool,
}

fn main() {
    let cli = Cli::parse();

    let filter = if cli.verbose { "debug" } else { "info" };
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(filter)),
        )
        .init();

    tracing::info!("stibbons v{}", env!("CARGO_PKG_VERSION"));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verify_cli() {
        use clap::CommandFactory;
        Cli::command().debug_assert();
    }
}
