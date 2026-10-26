# Audit scope

Written for an outside, independent security audit. Revision described:
`371ffbebfbd89512d9fc0d76e260e9ade49ea9d8` on `main`, 2026-10-26. Everything below is taken from the repository's own files at
that revision; items marked NOT_RUN were not executed while writing this document.

## What this repository is

An archived Rust crate `spark-supervisor` 0.1.0 (licence file: Sovereign Resource Commons License
1.0, Apache 2.0 with LLVM exceptions plus a rider). README: the canonical home is
`crates/spark-supervisor` in aien-dev/aien-sovereign-core. Four source files, 468 lines:

- `src/main.rs`: CLI (`run`, `status`, `check`). Default config path is
  `$HOME/.config/aien/supervisor.toml`; if it is missing, the program writes a default file there.
- `src/config.rs`: `ServiceConfig` (`command`, `args`, `env`, `restart`, `health_url`).
- `src/supervisor.rs`: spawn, restart with backoff, health polling with a 1.5 s HTTP timeout.
- `src/proc_telemetry.rs`: reads `/proc/<pid>/stat` and `/proc/<pid>/status`.

## What to review, in priority order

1. `src/supervisor.rs` `supervise_loop`: a leading `~/` in `command` is expanded from `HOME` (or
   `USERPROFILE`, or `.`), then `tokio::process::Command::new` runs it with `args` and every `env`
   entry from the config. No shell is used. Check what the child inherits from the supervisor's own
   environment.
2. `.github/workflows/sovereign-reviewer.yml` (tracked at this revision): on `pull_request_target`
   it checks out this repository plus `aien-dev/aien-sovereign-core` and `aien-dev/aien-protocols`
   with no `ref`, builds `spark-inquisitor`, feeds it the PR diff, title and author, and posts
   comments and labels with `GITHUB_TOKEN`. The `issues` and `issue_comment` jobs pass issue and
   comment bodies through files read with `jq`. Check whether untrusted text can reach a shell or
   the token.
3. `src/main.rs`: default config creation and directory creation under `HOME`.
4. `src/proc_telemetry.rs`: parsing of `/proc` fields.
5. `.github/workflows/ci.yml`: fmt, check, test on `ubuntu-latest`, `contents: read`.

## Trust boundaries

- Trusted: the config file and its owner; every configured command runs with the supervisor's
  privileges.
- Untrusted: health endpoint responses (only the status is used, per README); `/proc` contents of
  children; in the reviewer workflow, PR diffs, titles, issue and comment text.

## Threat model summary

- Assets: the host account that runs the supervisor; the repository's `GITHUB_TOKEN` in workflows.
- Attackers considered: a crashing or hostile child; a PR or issue author reaching the reviewer
  workflow.
- Defended: no shell in the spawn path; typed config parsing; workflows set explicit permissions.
- Not defended / explicitly out of scope: a hostile config file (it names the commands to run);
  privilege separation between supervisor and children (none in the code). README says the daemon
  resolves secrets through `atlas-vault`; no vault call appears in `src/`.

## Build from source at a pin

No `Cargo.lock` is tracked at this revision, so dependency versions are not pinned. Direct
dependencies in `Cargo.toml`: tokio 1.37, serde 1.0, serde_json 1.0, toml 0.8, clap 4.5, tracing
0.1, tracing-subscriber 0.3, chrono 0.4, reqwest 0.12 (`rustls-tls`).

```sh
git clone https://github.com/aien-dev/spark-supervisor
cd spark-supervisor
cargo build --release
```

## Run every test

NOT_RUN while writing this document. From README and `.github/workflows/ci.yml`:

```sh
cargo fmt --all -- --check
cargo check --all-targets
cargo test --verbose
```

Three `#[test]` functions exist (two in `src/config.rs`, one in `src/supervisor.rs`). There is no
`tests/` directory.

## Known limitations and NOT_RUN

- Archived; fixes are expected in the canonical crate.
- README claims (sub-millisecond respawn, under 2 MB resident memory, TPM vault integration) have
  no measurement or code evidence in this repository.
- No lockfile at this revision.

## Dependencies and provenance

- Crates listed above, resolved at build time from crates.io.
- Actions are referenced by tag (`actions/checkout@v4`, `dtolnay/rust-toolchain@stable`); the
  reviewer workflow builds code from two other repositories at their default branch.

## Evidence

None committed. No test logs, receipts or measurements are tracked in this repository.
