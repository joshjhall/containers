//! `stibbons labels sync` and `stibbons setup` — repository configuration.
//!
//! Both currently reconcile skill-defined labels onto the issue tracker;
//! `setup` is the umbrella that will grow further steps (branch protection, CI
//! templates), which is why they are separate entry points over one body.

use crate::cli::SyncArgs;
use crate::labels;

/// Runs `stibbons labels sync`: reconcile skill-defined labels onto the repo's
/// issue tracker.
pub fn run_labels_sync(args: SyncArgs) -> Result<(), Box<dyn std::error::Error>> {
    let opts = args.into_options()?;
    labels::run_sync(&opts)
}

/// Runs `stibbons setup`: repo configuration. Currently this is label sync;
/// future steps (branch protection, CI templates) will be added here.
pub fn run_setup(args: SyncArgs) -> Result<(), Box<dyn std::error::Error>> {
    let opts = args.into_options()?;
    labels::run_sync(&opts)?;
    println!("\nSetup complete. (Future steps: branch protection, CI templates.)");
    Ok(())
}
