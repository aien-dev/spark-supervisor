# Security policy

## Reporting a vulnerability

Report privately. Do not open a public issue, pull request or discussion about it.

1. GitHub: open this repository's Security tab and choose "Report a vulnerability". This
   creates a private advisory that only the maintainers can see. If that option is not shown,
   private vulnerability reporting has not been enabled for this repository yet; use email.
2. Email: drake@aienos.com with the subject `[spark-supervisor] security report`.

Include the commit or release you tested, the component (path), steps to reproduce, and what an
attacker gains. If the report involves a secret, say where it was exposed and do not send the
secret itself. Encrypted mail is not required; do not post proof-of-concept payloads publicly.

## Response targets

This project has one maintainer; the targets below are best effort and stated honestly.

- Acknowledgement: within 3 working days.
- Triage and severity: within 7 days of acknowledgement.
- Fix or mitigation for confirmed issues: aim for 30 days for high and critical, 90 days
  otherwise, with a status update at least every 14 days until closed.
- Disclosure: coordinated. An advisory is published with credit (unless you ask otherwise)
  once the fix is on the default branch. Default embargo 90 days, negotiable.

## Scope

This repository is archived. README: it is no longer authoritative, and the canonical home is
`crates/spark-supervisor` in aien-dev/aien-sovereign-core. History is kept read-only. Report issues
that also affect the canonical crate there; reports against this archived code are still accepted.

`spark-supervisor` is a Rust daemon that starts the services named in a TOML file, restarts them
by policy, polls their health URLs, and reads `/proc/<pid>` for memory and CPU figures.

In scope:

- Command or argument injection through `supervisor.toml`, or a config path that makes the
  supervisor run something other than the configured command.
- Unsafe handling of the `env` table passed to children.
- Parsing faults in `/proc` telemetry (`src/proc_telemetry.rs`).
- The tracked GitHub workflows at this revision, including `doctrine-audit.yml`, which runs on
  `push` and `pull_request` with `contents: read` and builds `spark-inquisitor` from a pinned
  commit.

Rules stated by the previous policy, kept here as the repository's intent:

- Zero plaintext API tokens or keys on disk.
- Daemons and internal IPC default to `127.0.0.1`. The supervisor itself opens no listening
  socket; the default health URLs it writes are on `127.0.0.1`.
- Untrusted inputs are schema-validated before processing (the config is parsed by `serde` and
  `toml` into fixed structs).

Out of scope: the supervised services themselves, the host operating system.

## Supported versions

None. The repository is archived; Cargo version `0.1.0` was the only line. Reports against older commits are welcome but fixes land on the default branch only.

## Status

Archived. No release, no certification, no bug bounty. See AUDIT_SCOPE.md for what to review and how to build and test it.
