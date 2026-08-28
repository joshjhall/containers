//! Crate-wide test helpers.
//!
//! Home of the **single** process-CWD guard. Several code paths under test read
//! *relative* paths ([`crate::render::plan_render`] classifies generated files
//! by relative path; [`crate::commands::shared::detect_containers_dir`] probes
//! `containers/Dockerfile` and friends), so their tests must point the process
//! CWD at a temp dir.
//!
//! All `src/` unit tests compile into one test binary that cargo runs
//! multi-threaded, and the CWD is process-global. Two independently-locked CWD
//! test surfaces would race intermittently — so every such test serializes on
//! the one [`with_cwd`] here rather than on a per-module mutex.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// Serializes tests that mutate the process-global current directory.
static CWD_LOCK: Mutex<()> = Mutex::new(());

/// Restores the process CWD to its captured value when dropped.
struct RestoreCwd(PathBuf);

impl Drop for RestoreCwd {
    fn drop(&mut self) {
        let _ = std::env::set_current_dir(&self.0);
    }
}

/// Runs `f` with the process CWD set to `dir`, restoring the previous CWD (and
/// releasing the lock) even if `f` panics.
///
/// The lock is recovered from poisoning: a panic inside one `f` leaves the CWD
/// restored by [`RestoreCwd`], so the guarded state is still sound for the next
/// caller and poisoning would only cascade one test failure into many.
pub fn with_cwd<T>(dir: &Path, f: impl FnOnce() -> T) -> T {
    let _guard = CWD_LOCK.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let _restore = RestoreCwd(std::env::current_dir().unwrap());
    std::env::set_current_dir(dir).unwrap();
    f()
}
