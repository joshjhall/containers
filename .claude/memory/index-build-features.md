# Build & feature-script specifics

<!-- rumdl-disable MD013 -->
Sub-index of [MEMORY.md](MEMORY.md): open when editing Dockerfile/base-image layers, per-language feature scripts, or stibbons packaging.

- [aarch64 release native not cross](aarch64-release-native-not-cross.md) — release-binaries aarch64 leg builds native on ubuntu-24.04-arm
- [Alpine hardening: no coreutils paths](alpine-hardening-no-coreutils-paths.md) — Alpine build scripts use bare command names, not /usr/bin/<cmd>
- [UBI image tag verify against registry](ubi-image-tag-verify-registry.md) — UBI FROM tags: no bare :9, floating minors cap at 9.5
- [ubi-minimal no nologin → use /usr/bin/false](ubi-minimal-no-nologin-use-false.md) — ubi-minimal ships no nologin (not even via util-linux-core)
- [UBI arm64 mirror depsolve flake](ubi-arm64-mirror-depsolve-flake.md) — rhel-9-arm64 base build fails on transient microdnf glibc depsolve
- [Base-image publish path vs PR Trivy arch](base-image-publish-path-trivy-arch.md) — PR scans local single-arch
- [Cache mounts not on install dirs](cache-mounts-not-on-install-dirs.md) — no type=cache on /cache/cargo or /cache/r (runtime install locations)
- [cargo missing from non-login/shebang shells](cargo-path-missing-luggage-rust.md) — luggage rust: /cache/cargo/bin empty, /usr/local/bin/cargo
- [Rust tools use cargo binstall](rust-tools-use-cargo-binstall.md) — rust.sh/rust-dev.sh install via cargo binstall
- [R packages use PPM binaries](r-packages-use-ppm-binaries.md) — CRAN from Posit PPM binaries (x86_64 only
- [Node 25+ install deps](node-25-plus-install-deps.md) — no bundled corepack (≥25) + libatomic1 on Node 26 arm64
- [dist profile scoping](dist-profile-scoping.md) — stibbons size tuning lives in [profile.dist] not workspace-wide…
- [stibbons binary distribution](stibbons-binary-distribution.md) — VERSION-file injection via build.rs, release-binaries.yml 6-target matrix
- [Services reuse agent Docker layer](services-reuse-agent-docker-layer.md) — stibbons services (#311) assembled on #310's shared layer
- [Label metadata reference vs definition](label-metadata-reference-vs-definition.md) — stibbons labels sync (#289): defs live in
