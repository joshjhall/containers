# Container runtime, entrypoint, Zed & permissions

<!-- rumdl-disable MD013 -->
Sub-index of [MEMORY.md](MEMORY.md): open when debugging the entrypoint, UID handling, Zed/devcontainer startup, cron or logging inside the image.

- [Container UID fixed, not remapped](container-uid-fixed-not-remapped.md) — updateRemoteUserUID:false keeps 1000:1000
- [entrypoint UID-agnostic user](entrypoint-uid-agnostic-user-detection.md) — resolve runtime user by shape, not hardcoded UID
- [tmpfs uid can't be templated](tmpfs-uid-cannot-be-templated.md) — compose tmpfs uid=/gid= baked at mount time
- [Build-time chown breaks UID remap](build-time-chown-breaks-uid-remap.md) — a build-time owner is wrong under Zed's remap
- [Zed every-boot startup replay](zed-every-boot-startup-replay.md) — Zed replaces ENTRYPOINT
- [Zed postStart races entrypoint](zed-poststart-races-entrypoint.md) — postStart fires T+147ms, entrypoint finishes T+3s
- [Cron legs need a boot env snapshot](cron-legs-need-boot-env-snapshot.md) — periodic leg of a startup script sees no container env
- [cron user column is build-time](cron-user-column-is-build-time.md) — run cron jobs as root + resolve the container user at run time
- [logger without a syslog daemon](logger-without-syslog-daemon.md) — no /dev/log in these images
- [jsonc-merge helper (#529)](jsonc-merge-helper-529.md) — Node CLI + jsonc-parser for comment-preserving Zed settings.json merges
- [claude-setup template stamp re-sync](claude-setup-template-stamp-resync.md) — bundled ~/.claude artifacts re-sync via content stamp (#574)
