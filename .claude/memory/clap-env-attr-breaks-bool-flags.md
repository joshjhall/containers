---
name: clap-env-attr-breaks-bool-flags
description: clap's #[arg(env = "...")] turns a bool flag into a value-taking arg, breaking bare switches and hard-erroring on set-but-empty vars
metadata:
  type: project
---

Adding `#[arg(long, env = "VAR")]` to a `bool` field in a clap derive struct
does **not** give you "a switch that can also be set from the environment". It
makes the argument *value-taking*: `--flag` alone then fails with
`a value is required for '--flag' but none was supplied  [possible values:
true, false]`, and a set-but-**empty** `VAR=` in the environment fails the same
way — before any subcommand runs, so every CLI invocation dies, including ones
that never touch the flag.

Both failure modes bit at once on #810 (luggage `--require-verified-downloads`,
`REQUIRE_VERIFIED_DOWNLOADS`): the container image exports the variable empty,
so `tests/cli.rs` went red on unrelated `install --dry-run` cases.

Read the env var explicitly instead — a plain `std::env::var(...)` OR-ed with
the flag — and split the value parsing into a pure function taking
`Option<&str>` so it is testable without mutating process-wide env state (which
races the rest of the test binary).

When porting a bash env var, port its **whole** rule, not just the literal
comparison: `REQUIRE_VERIFIED_DOWNLOADS` in
`lib/base/checksum-verification.sh` falls back to `PRODUCTION_MODE` whenever it
is not explicitly `true`/`false`. Dropping that fallback made a security
control fail *open* under luggage while still refusing under bash. Also parse
by **value**, never by presence — treating "the variable exists" as consent
flips behavior for every build environment that exports it empty.

Related: [[luggage-installreport-field-workspace-test]]
