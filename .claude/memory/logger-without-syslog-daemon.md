---
name: logger-without-syslog-daemon
description: "These images ship no syslog daemon — `logger` discards output and still exits 0; use a log file for cron output"
metadata:
  node_type: memory
  type: project
  originSessionId: d7837678-6b9f-4041-849b-70d0422e6e1a
  modified: 2026-08-22T18:46:47.519Z
---

These container images install **no syslog daemon** (no rsyslog, no syslog-ng,
no busybox syslogd). There is no `/dev/log` socket and no `/var/log/syslog`.

`logger -t foo "msg"` therefore **discards the message and still exits 0** —
verified live in-container 2026-08-22. Nothing errors, nothing is written,
nothing is findable. Existing `logger -t` calls in `lib/features/bindfs.sh`
(fuse-cleanup) and `lib/features/rust-dev.sh` (cargo-sweep) share this latent
assumption, as does the `cron-logs` alias's `/var/log/syslog` grep.

**Why:** for a cron job whose whole point is surfacing a signal, routing to
`logger` recreates the silent-failure class the job exists to remove. Caught by
adversarial review on #800 before merge.

**How to apply:** for cron output, redirect to a dedicated file
(`>> /var/log/<name>.log 2>&1`) created at build time, then `chgrp
"${USERNAME}"` and `chmod 640` it — root:root 640 is unreadable to the container user, whose
groups are its own primary group plus sudo and docker, never root. A plain
redirect also keeps cron seeing the job's real exit status; a `| logger`
pipeline masks it behind logger's reliable 0. See
[[cron-legs-need-boot-env-snapshot]] and [[entrypoint-uid-agnostic-user-detection]].
