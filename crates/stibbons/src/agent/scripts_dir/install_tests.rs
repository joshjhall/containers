//! Concurrency and install tests for [`super::install`] (#927, #1646).

use std::path::{Path, PathBuf};

use super::install::*;
#[cfg(unix)]
use super::tests::mode_of;
use super::tests::scripts;
use super::*;

/// Hidden staging/aside entries left in the `agent-scripts` parent. Every
/// prepare — success or failure — must leave none (#927).
fn leftovers(state_root: &Path) -> Vec<String> {
    let parent = state_root.join("stibbons").join("agent-scripts");
    std::fs::read_dir(parent)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with('.'))
        .collect()
}

/// Asserts `dir` holds exactly `expected`, byte for byte.
fn assert_complete(dir: &Path, expected: &[(&str, &str)]) {
    let mut names: Vec<_> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    let mut want: Vec<_> = expected.iter().map(|(n, _)| (*n).to_owned()).collect();
    want.sort();
    assert_eq!(names, want, "{}", dir.display());
    for (name, body) in expected {
        assert_eq!(std::fs::read_to_string(dir.join(name)).unwrap(), *body, "{name}");
    }
}

/// Runs invocation A up to `pause_at`, runs B to completion in that gap,
/// then lets A finish. Barriers, not sleeps, so the interleaving is the
/// same every run (#927).
fn interleave(
    root: &Path,
    a_scripts: &[(&'static str, &'static str)],
    b_scripts: &[(&'static str, &'static str)],
    pause_at: Stage,
) -> (PathBuf, PathBuf) {
    use std::sync::{Arc, Barrier};

    let paused = Arc::new(Barrier::new(2));
    let resume = Arc::new(Barrier::new(2));
    let a = {
        let (root, scripts) = (root.to_path_buf(), a_scripts.to_vec());
        let (paused, resume) = (Arc::clone(&paused), Arc::clone(&resume));
        std::thread::spawn(move || {
            let mut hit = false;
            let dir = prepare_with_hook(Some(&root), "myproject-agent-1", &scripts, &mut |s| {
                if s == pause_at && !hit {
                    hit = true;
                    paused.wait();
                    resume.wait();
                }
            });
            // A that returns before its pause point must still release the
            // main thread, or a regression hangs the suite instead of
            // failing it.
            if !hit {
                paused.wait();
                resume.wait();
            }
            assert!(hit, "A never reached {pause_at:?}: {dir:?}");
            dir
        })
    };
    paused.wait();
    let b = prepare_scripts_dir(Some(root), "myproject-agent-1", b_scripts).unwrap();
    resume.wait();
    (a.join().unwrap().unwrap(), b)
}

/// The scripts with one body changed — a different stibbons version.
fn other_scripts() -> Vec<(&'static str, &'static str)> {
    let mut s = scripts();
    s[1].1 = "#!/bin/bash\ninit v2\n";
    s
}

/// #927 acceptance: A has built its scripts but not installed them when B
/// runs a whole prepare for the same container. Both must come back with
/// the full script set — under the old remove-then-write sequence, B's
/// `remove_dir_all` deleted A's half-written tree.
#[test]
fn concurrent_prepare_same_scripts_both_complete() {
    let tmp = tempfile::tempdir().unwrap();

    let (a, b) = interleave(tmp.path(), &scripts(), &scripts(), Stage::Built);

    assert_eq!(a, b);
    assert_complete(&a, &scripts());
    assert_eq!(leftovers(tmp.path()), Vec::<String>::new(), "leaked siblings");
}

/// The same race with differing content: A must replace B's tree whole,
/// never merge with it, and clear its staging and moved-aside copies.
#[test]
fn concurrent_prepare_different_scripts_last_install_wins_whole() {
    let tmp = tempfile::tempdir().unwrap();

    let (a, _) = interleave(tmp.path(), &other_scripts(), &scripts(), Stage::Built);

    assert_complete(&a, &other_scripts());
    assert_eq!(leftovers(tmp.path()), Vec::<String>::new(), "leaked siblings");
}

/// The narrower window: A has moved the old tree aside and the target is
/// momentarily absent when B installs. A's rename then hits B's tree and
/// must retry rather than fail or merge.
#[test]
fn concurrent_install_into_moved_aside_gap_retries() {
    let tmp = tempfile::tempdir().unwrap();
    prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();

    let (a, b) = interleave(tmp.path(), &other_scripts(), &scripts(), Stage::MovedAside);

    assert_eq!(a, b);
    assert_complete(&a, &other_scripts());
    assert_eq!(leftovers(tmp.path()), Vec::<String>::new(), "leaked siblings");
}

/// Finding (1), post-PR cycle 1: two FIRST-EVER starts race to create the
/// shared ancestors. A sees `stibbons` absent and pauses; B then runs a
/// whole prepare, creating it. A's `create_dir` now gets `AlreadyExists` —
/// which must read as "exists", not abort the start. Different containers,
/// because the ancestors are shared by all of them.
#[test]
fn concurrent_first_start_ancestor_race_is_tolerated() {
    use std::sync::{Arc, Barrier};
    let tmp = tempfile::tempdir().unwrap();
    let (paused, resume) = (Arc::new(Barrier::new(2)), Arc::new(Barrier::new(2)));

    let a = {
        let root = tmp.path().to_path_buf();
        let (paused, resume) = (Arc::clone(&paused), Arc::clone(&resume));
        std::thread::spawn(move || {
            let mut hit = false;
            let dir = prepare_with_hook(Some(&root), "myproject-agent-1", &scripts(), &mut |s| {
                if s == Stage::AncestorAbsent && !hit {
                    hit = true;
                    paused.wait();
                    resume.wait();
                }
            });
            if !hit {
                paused.wait();
                resume.wait();
            }
            assert!(hit, "A never saw an absent ancestor: {dir:?}");
            dir
        })
    };
    paused.wait();
    let b = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-2", &scripts()).unwrap();
    resume.wait();
    let a = a.join().unwrap().expect("AlreadyExists on a shared ancestor must be tolerated");

    assert_complete(&a, &scripts());
    assert_complete(&b, &scripts());
}

/// The tolerated `AlreadyExists` still goes through the ownership check: a
/// symlink planted at the ancestor in that same gap is refused, not
/// followed — the #924 boundary must not open up for the race fix.
#[cfg(unix)]
#[test]
fn ancestor_symlink_planted_in_race_gap_is_rejected() {
    let tmp = tempfile::tempdir().unwrap();
    let elsewhere = tempfile::tempdir().unwrap();
    let ancestor = tmp.path().join("stibbons");

    let err = prepare_with_hook(Some(tmp.path()), "myproject-agent-1", &scripts(), &mut |s| {
        if s == Stage::AncestorAbsent && !ancestor.exists() {
            std::os::unix::fs::symlink(elsewhere.path(), &ancestor).unwrap();
        }
    })
    .expect_err("a symlink at the ancestor must be refused");

    assert!(err.to_string().contains("is a symlink"), "{err}");
    assert_eq!(
        std::fs::read_dir(elsewhere.path()).unwrap().count(),
        0,
        "nothing written through the link"
    );
}

/// Finding (2), post-PR cycle 1, first site: the target exists when the
/// ancestors are done, then a concurrent start moves it aside before it is
/// inspected. That is "absent — build", not a hard `NotFound`.
#[test]
fn target_vanishing_before_inspection_builds() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();
    let elsewhere = tmp.path().join("moved-by-someone-else");

    let mut vanished = false;
    let got =
        prepare_with_hook(Some(tmp.path()), "myproject-agent-1", &other_scripts(), &mut |s| {
            if s == Stage::BeforeTargetCheck && !vanished {
                vanished = true;
                std::fs::rename(&dir, &elsewhere).unwrap();
            }
        })
        .expect("a target that vanished before inspection must be rebuilt");

    assert!(vanished);
    assert_complete(&got, &other_scripts());
    assert_eq!(leftovers(tmp.path()), Vec::<String>::new(), "leaked siblings");
}

/// The target vanishes between A's failed rename and its re-inspection —
/// another invocation moved it aside. A must treat that as "retry", not as
/// an error, and still install a complete tree.
#[test]
fn target_vanishing_after_failed_rename_is_retried() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();
    let elsewhere = tmp.path().join("moved-by-someone-else");

    let mut vanished = false;
    let got =
        prepare_with_hook(Some(tmp.path()), "myproject-agent-1", &other_scripts(), &mut |s| {
            if s == Stage::RenameFailed && !vanished {
                vanished = true;
                std::fs::rename(&dir, &elsewhere).unwrap();
            }
        })
        .unwrap();

    assert!(vanished, "rename never failed, so the branch was not reached");
    assert_complete(&got, &other_scripts());
    assert_eq!(leftovers(tmp.path()), Vec::<String>::new(), "leaked siblings");
}

/// A non-race rename failure is returned with its real cause — not retried
/// into a misleading "lost the race". Here the staged source vanishes
/// between build and install, so `rename` fails `ENOENT` with the target
/// absent: the retry-everything loop this replaced would spin through every
/// attempt and report a race. Driven by the hook rather than mode bits, so
/// it also holds when the suite runs as root.
#[test]
fn non_race_rename_failure_is_reported_not_retried() {
    let tmp = tempfile::tempdir().unwrap();
    let parent = tmp.path().join("stibbons").join("agent-scripts");

    let err = prepare_with_hook(Some(tmp.path()), "myproject-agent-1", &scripts(), &mut |s| {
        if s == Stage::Built {
            for entry in std::fs::read_dir(&parent).unwrap() {
                std::fs::remove_dir_all(entry.unwrap().path()).unwrap();
            }
        }
    })
    .expect_err("a vanished source must not be retried");

    match err {
        ScriptsDirError::Io { source, .. } => {
            assert_eq!(source.kind(), std::io::ErrorKind::NotFound, "{source}");
        }
        other => panic!("expected Io(NotFound), got {other}"),
    }
    assert_eq!(leftovers(tmp.path()), Vec::<String>::new(), "leaked siblings");
}

/// The retry bound holds: if every attempt loses to a fresh differing
/// occupant, prepare gives up with the attempt count in the error rather
/// than looping forever, and every tree it moved aside is removed.
#[cfg(unix)]
#[test]
fn retry_exhaustion_errors_and_cleans_up() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let dir = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();
    let mut planted = 0;

    let err =
        prepare_with_hook(Some(tmp.path()), "myproject-agent-1", &other_scripts(), &mut |s| {
            if s == Stage::MovedAside {
                planted += 1;
                std::fs::create_dir(&dir).unwrap();
                std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
                std::fs::write(dir.join("rival.sh"), "x").unwrap();
            }
        })
        .expect_err("a rival that always wins must exhaust the retries");

    assert_eq!(planted, MAX_INSTALL_ATTEMPTS, "one move-aside per attempt");
    let msg = err.to_string();
    assert!(msg.contains(&format!("after {MAX_INSTALL_ATTEMPTS} attempts")), "{msg}");
    assert_eq!(leftovers(tmp.path()), Vec::<String>::new(), "leaked siblings");
}

/// Script names get the same single-component rule as the container name:
/// one is joined onto the staging dir and chmod'd 0755, so `..` or a
/// separator would write outside it. Refused before anything is created.
#[test]
fn traversing_script_name_is_rejected() {
    let tmp = tempfile::tempdir().unwrap();

    for name in ["../escape.sh", "sub/x.sh", "..", "", "x.sh/"] {
        let mut bad = scripts();
        bad.push((name, "x"));
        let err = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &bad)
            .expect_err("must be rejected");
        assert!(err.to_string().contains("script name"), "{name:?}: {err}");
    }
    assert!(!tmp.path().join("stibbons").exists(), "nothing created for a refused name");
}

/// A foreign occupant that appears at the target mid-install (here our own
/// tree opened to 0755 — what an attacker-planted dir looks like) is
/// rejected rather than moved aside and replaced, and the staging dir does
/// not leak on that error path.
#[cfg(unix)]
#[test]
fn foreign_occupant_appearing_mid_install_is_rejected() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let dir = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();

    let err =
        prepare_with_hook(Some(tmp.path()), "myproject-agent-1", &other_scripts(), &mut |s| {
            if s == Stage::RenameFailed {
                std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
            }
        })
        .expect_err("an open-mode occupant must be refused");

    assert!(matches!(err, ScriptsDirError::UnsafePath { .. }), "{err}");
    assert_complete(&dir, &scripts());
    assert_eq!(leftovers(tmp.path()), Vec::<String>::new(), "leaked siblings");
}

/// The "already matches, leave it" short-circuit must not accept a tree
/// that differs in anything but script bytes: a tampered mode, an extra
/// file, or a script swapped for a symlink each force a full replacement.
/// These are the cases where returning the tree untouched would carry
/// someone else's change into the mount.
#[cfg(unix)]
#[test]
fn near_match_trees_are_replaced() {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    type Tamper = fn(&Path);
    let tampers: [(&str, Tamper); 3] = [
        ("mode", |d| {
            std::fs::set_permissions(
                d.join("agent-init.sh"),
                std::fs::Permissions::from_mode(0o777),
            )
            .unwrap();
        }),
        ("extra file", |d| std::fs::write(d.join("extra.sh"), "x").unwrap()),
        ("symlink", |d| {
            let target = d.parent().unwrap().parent().unwrap().join("init-copy");
            std::fs::write(&target, "#!/bin/bash\ninit\n").unwrap();
            std::fs::remove_file(d.join("agent-init.sh")).unwrap();
            std::os::unix::fs::symlink(&target, d.join("agent-init.sh")).unwrap();
        }),
    ];
    for (what, tamper) in tampers {
        let tmp = tempfile::tempdir().unwrap();
        let dir = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();
        tamper(&dir);
        let ino = std::fs::metadata(&dir).unwrap().ino();

        prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();

        assert_ne!(std::fs::metadata(&dir).unwrap().ino(), ino, "{what}: not replaced");
        assert_complete(&dir, &scripts());
        assert_eq!(mode_of(&dir.join("agent-init.sh")), 0o755, "{what}");
        assert!(
            !std::fs::symlink_metadata(dir.join("agent-init.sh")).unwrap().is_symlink(),
            "{what}"
        );
    }
}

/// Only an occupied-target kind is retried; every other kind is reported.
/// The Windows `PermissionDenied` arm is `cfg!`-gated, so on Unix that kind
/// must stay a hard error even when the target exists.
#[test]
fn target_occupied_classifies_by_kind() {
    use std::io::{Error, ErrorKind};
    let tmp = tempfile::tempdir().unwrap();
    let (present, absent) = (tmp.path(), tmp.path().join("absent"));

    assert!(target_occupied(&Error::from(ErrorKind::AlreadyExists), present));
    assert!(target_occupied(&Error::from(ErrorKind::DirectoryNotEmpty), present));
    assert!(!target_occupied(&Error::from(ErrorKind::PermissionDenied), &absent));
    assert!(!target_occupied(&Error::from(ErrorKind::StorageFull), present));
    assert!(!target_occupied(&Error::from(ErrorKind::Other), present));
    assert_eq!(target_occupied(&Error::from(ErrorKind::PermissionDenied), present), cfg!(windows),);
}

/// Sibling names never repeat within a process and stay hidden, so they
/// can neither collide with each other nor with a container name.
#[test]
fn sibling_names_are_hidden_and_unique() {
    let parent = Path::new("/p");
    let a = sibling(parent, "c", "tmp");
    let b = sibling(parent, "c", "tmp");

    assert_ne!(a, b);
    for p in [&a, &b] {
        let name = p.file_name().unwrap().to_string_lossy();
        assert!(name.starts_with(".c.tmp-"), "{name}");
        // pid, nanos, seq
        assert_eq!(name.trim_start_matches(".c.tmp-").split('-').count(), 3, "{name}");
    }
}

/// A tree that already holds these exact scripts is left in place — same
/// inode — so a concurrent start that has bind-mounted it keeps its files.
#[cfg(unix)]
#[test]
fn unchanged_scripts_leave_dir_in_place() {
    use std::os::unix::fs::MetadataExt;
    let tmp = tempfile::tempdir().unwrap();
    let dir = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();
    let ino = std::fs::metadata(&dir).unwrap().ino();

    prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();

    assert_eq!(std::fs::metadata(&dir).unwrap().ino(), ino);
}

/// Changed content replaces the tree rather than editing it in place.
#[cfg(unix)]
#[test]
fn changed_scripts_replace_the_dir() {
    use std::os::unix::fs::MetadataExt;
    let tmp = tempfile::tempdir().unwrap();
    let dir = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();
    let ino = std::fs::metadata(&dir).unwrap().ino();

    prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &other_scripts()).unwrap();

    assert_ne!(std::fs::metadata(&dir).unwrap().ino(), ino);
    assert_complete(&dir, &other_scripts());
    assert_eq!(leftovers(tmp.path()), Vec::<String>::new(), "leaked siblings");
}

/// A script that fails to write aborts the prepare without leaking the
/// staging directory, and leaves an existing installed tree intact.
#[test]
fn failed_build_leaks_no_staging_dir() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();

    // A NUL byte passes the single-component check but fails the write
    // itself, so the failure lands mid-build, after staging exists.
    let mut bad = scripts();
    bad.push(("bad\0name.sh", "x"));
    prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &bad)
        .expect_err("a write that fails mid-build must fail the prepare");

    assert_eq!(leftovers(tmp.path()), Vec::<String>::new(), "leaked siblings");
    assert_complete(&dir, &scripts());
}

/// Restores a directory locked by [`lock_aside`] to `0700` on drop, so
/// `tempdir` can still remove it if an assertion panics first.
#[cfg(unix)]
struct RestoreMode(PathBuf);

#[cfg(unix)]
impl Drop for RestoreMode {
    fn drop(&mut self) {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&self.0, std::fs::Permissions::from_mode(0o700));
    }
}

/// Whether a `0500` directory really refuses a new entry here. It does not
/// under root or `CAP_DAC_OVERRIDE`, and then the cleanup failure the
/// tests below need cannot happen. CI runs unprivileged and sets
/// `REQUIRE_UNPRIVILEGED_TESTS=1`, so there a skip counts as a failure (the
/// same idiom as `standards/fsutil.rs`).
#[cfg(unix)]
fn mode_bits_are_enforced(scratch: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    let probe = scratch.join("probe");
    std::fs::create_dir(&probe).unwrap();
    std::fs::set_permissions(&probe, std::fs::Permissions::from_mode(0o500)).unwrap();
    let enforced = std::fs::write(probe.join("x"), "x").is_err();
    std::fs::set_permissions(&probe, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::remove_dir_all(&probe).unwrap();
    if !enforced {
        assert!(
            std::env::var("REQUIRE_UNPRIVILEGED_TESTS").as_deref() != Ok("1"),
            "REQUIRE_UNPRIVILEGED_TESTS=1 but a 0500 dir is writable (running as root?)"
        );
        eprintln!("skipping: a 0500 dir is writable here (running as root?)");
    }
    enforced
}

/// Makes the single moved-aside tree of `myproject-agent-1` undeletable:
/// a `0500` subdirectory holding a file, which `remove_dir_all` cannot
/// empty. Returns the aside path and the guard that unlocks it.
#[cfg(unix)]
fn lock_aside(state_root: &Path) -> (PathBuf, RestoreMode) {
    use std::os::unix::fs::PermissionsExt;
    let parent = state_root.join("stibbons").join("agent-scripts");
    let asides: Vec<PathBuf> = std::fs::read_dir(&parent)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.file_name().unwrap().to_string_lossy().starts_with(".myproject-agent-1.old-"))
        .collect();
    assert_eq!(asides.len(), 1, "exactly one aside at MovedAside: {asides:?}");
    let aside = asides.into_iter().next().unwrap();
    let locked = aside.join("locked");
    std::fs::create_dir(&locked).unwrap();
    std::fs::write(locked.join("pin"), "x").unwrap();
    std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o500)).unwrap();
    (aside, RestoreMode(locked))
}

/// #1646: if a moved-aside tree cannot be removed after a successful
/// install, the prepare fails with an `Io` error naming that aside path,
/// even though the target is complete. The leak is reported, not hidden.
#[cfg(unix)]
#[test]
fn aside_cleanup_failure_after_successful_install_is_reported() {
    let tmp = tempfile::tempdir().unwrap();
    if !mode_bits_are_enforced(tmp.path()) {
        return;
    }
    let dir = prepare_scripts_dir(Some(tmp.path()), "myproject-agent-1", &scripts()).unwrap();
    let mut locked = None;

    let err =
        prepare_with_hook(Some(tmp.path()), "myproject-agent-1", &other_scripts(), &mut |s| {
            if s == Stage::MovedAside {
                locked = Some(lock_aside(tmp.path()));
            }
        })
        .expect_err("an aside that cannot be removed must fail the prepare");

    let (aside, _guard) = locked.expect("the hook locked an aside");
    match &err {
        ScriptsDirError::Io { path, .. } => {
            assert_eq!(*path, aside.display().to_string(), "{err}");
        }
        other => panic!("expected Io naming the aside, got {other:?}"),
    }
    assert_complete(&dir, &other_scripts());
    let aside_name = aside.file_name().unwrap().to_string_lossy().into_owned();
    assert_eq!(leftovers(tmp.path()), vec![aside_name], "only the reported aside leaks");
}

/// Drives a prepare that moves the old tree aside and then fails: at
/// `MovedAside` an open-mode occupant is planted at the target, so the
/// retried rename hits it and the loop refuses it with `UnsafePath`. With
/// `lock`, the aside is also made undeletable first. Returns the error,
/// the aside path, and the lock guard (if any).
#[cfg(unix)]
fn failed_install_with_aside(
    state_root: &Path,
    lock: bool,
) -> (ScriptsDirError, PathBuf, Option<RestoreMode>) {
    use std::os::unix::fs::PermissionsExt;
    let dir = prepare_scripts_dir(Some(state_root), "myproject-agent-1", &scripts()).unwrap();
    let parent = dir.parent().unwrap().to_owned();
    let mut seen = None;

    let err =
        prepare_with_hook(Some(state_root), "myproject-agent-1", &other_scripts(), &mut |s| {
            if s == Stage::MovedAside {
                seen = Some(if lock {
                    let (aside, guard) = lock_aside(state_root);
                    (aside, Some(guard))
                } else {
                    let aside = std::fs::read_dir(&parent)
                        .unwrap()
                        .map(|e| e.unwrap().path())
                        .find(|p| {
                            p.file_name()
                                .unwrap()
                                .to_string_lossy()
                                .starts_with(".myproject-agent-1.old-")
                        })
                        .expect("an aside exists at MovedAside");
                    (aside, None)
                });
                std::fs::create_dir(&dir).unwrap();
                std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
                std::fs::write(dir.join("rival.sh"), "x").unwrap();
            }
        })
        .expect_err("an open-mode occupant must be refused");

    let (aside, guard) = seen.expect("the hook saw the aside");
    (err, aside, guard)
}

/// #1646: when the install itself fails, its error wins over an aside
/// cleanup failure (the first error is returned). The unlocked control run
/// goes through the same failed install and must leave no aside, which
/// shows the cleanup is attempted on this error path. The locked run's
/// surviving aside therefore comes from a removal that failed and was
/// dropped, not from a removal that was skipped.
#[cfg(unix)]
#[test]
fn aside_cleanup_failure_after_failed_install_reports_install_error() {
    let tmp = tempfile::tempdir().unwrap();
    if !mode_bits_are_enforced(tmp.path()) {
        return;
    }

    // Control: same failure, removable aside, so it must be gone.
    let control = tempfile::tempdir().unwrap();
    let (err, aside, _) = failed_install_with_aside(control.path(), false);
    assert!(matches!(err, ScriptsDirError::UnsafePath { .. }), "control: {err:?}");
    assert!(!aside.exists(), "cleanup skipped on the error path: {}", aside.display());
    assert_eq!(leftovers(control.path()), Vec::<String>::new(), "control leaked siblings");

    // Locked: the removal fails, and the install error still wins.
    let (err, aside, _guard) = failed_install_with_aside(tmp.path(), true);
    assert!(matches!(err, ScriptsDirError::UnsafePath { .. }), "{err:?}");
    let aside_name = aside.file_name().unwrap().to_string_lossy().into_owned();
    assert_eq!(leftovers(tmp.path()), vec![aside_name], "only the locked aside survives");
}
