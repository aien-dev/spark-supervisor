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
2. `.github/workflows/doctrine-audit.yml`: on `push` and `pull_request` (never
   `pull_request_target`), with `contents: read` and `persist-credentials: false`, it checks out
   this repository plus `aien-dev/aien-sovereign-core-mv` and `aien-dev/aien-protocols-mv` at
   pinned commit shas, builds `spark-inquisitor`, and runs `spark-inquisitor review` on the diff.
   Any finding fails the check; nothing is posted back. PR title and author reach the tool only
   through environment variables. Check whether untrusted diff or title text can reach a shell.
   It replaces the retired `sovereign-reviewer.yml` (`pull_request_target`, `issues`,
   `issue_comment`, write token, comment posting).
3. `src/main.rs`: default config creation and directory creation under `HOME`.
4. `src/proc_telemetry.rs`: parsing of `/proc` fields.
5. `.github/workflows/ci.yml`: fmt, check, test on `ubuntu-latest`, `contents: read`.

## Trust boundaries

- Trusted: the config file and its owner; every configured command runs with the supervisor's
  privileges.
- Untrusted: health endpoint responses (only the status is used, per README); `/proc` contents of
  children; in the doctrine audit workflow, PR diffs, titles and author names.

## Threat model summary

- Assets: the host account that runs the supervisor; the repository's `GITHUB_TOKEN` in workflows.
- Attackers considered: a crashing or hostile child; a PR author reaching the doctrine audit
  workflow.
- Defended: no shell in the spawn path; typed config parsing; workflows set explicit permissions.
- Not defended / explicitly out of scope: a hostile config file (it names the commands to run);
  privilege separation between supervisor and children (none in the code). README says the daemon
  resolves secrets through `atlas-vault`; no vault call appears in `src/`.

## Build from source at a pin

`Cargo.lock` is tracked and CI builds with `--locked`. Direct dependencies in `Cargo.toml`: tokio
1.37, serde 1.0, serde_json 1.0, toml 0.8, clap 4.5, tracing 0.1, tracing-subscriber 0.3, chrono
0.4, reqwest 0.12 (`rustls-tls`).

```sh
git clone https://github.com/aien-dev/spark-supervisor
cd spark-supervisor
cargo build --release
```

## Run every test

NOT_RUN while writing this document. From README and `.github/workflows/ci.yml`:

```sh
cargo fmt --all -- --check
cargo check --locked --all-targets
cargo test --locked --verbose
```

Three `#[test]` functions exist (two in `src/config.rs`, one in `src/supervisor.rs`). There is no
`tests/` directory.

## Known limitations and NOT_RUN

- Archived; fixes are expected in the canonical crate.
- README claims (sub-millisecond respawn, under 2 MB resident memory, TPM vault integration) have
  no measurement or code evidence in this repository.
- The doctrine audit trusts the pinned `spark-inquisitor` source; bump its sha deliberately.

## Dependencies and provenance

- Crates listed above, pinned by `Cargo.lock`, fetched from crates.io.
- Actions are pinned by commit sha. The doctrine audit builds code from two other repositories at
  the commit shas named in its `env` block.

## Evidence

None committed. No test logs, receipts or measurements are tracked in this repository.
