# Migration off systemd units (Spark, 2026-10-26)

Status words: MIGRATED (runs under aien-supervise, systemd unit removed), READY (service file
written and its sandbox qualified, systemd unit still live), REMAINING (not moved, reason given).
Nothing below is MIGRATED yet: cutting a live service over is the owning lane's step, after its own
isolation tests pass under aien-supervise (see "Cutover" at the end).

## 1. Inventory

Source: `systemctl --user list-unit-files`, `~/.config/systemd/user/`, and the files under
`/etc/systemd/system/` that no package owns (`dpkg -S`). Distribution units (gdm, pipewire,
snapd, dgx-dashboard, nut, ...) are not AIEN services and are out of scope.

### System units (`/etc/systemd/system`) and supervised processes

| Service | Role | Risk | Order | Status, reason |
| --- | --- | --- | --- | --- |
| allen-chat (.service) | public Allen gateway, tailnet 18110 + console 18112 | high: public input | 1 | READY: `services/allen-chat.svc`; AllenChat reruns its probes, then cuts over |
| allen-catalog (.service + .timer) | daily public GitHub read for Allen | low | 1 | READY: `services/allen-catalog.svc` (real run inside the sandbox wrote catalog.txt) |
| allen-contacts-ingest (.service + .path) | moves contact drops to the private store (.om binary) | medium: private data | 1 | READY: `services/allen-contacts-ingest.svc` (aien-watch trigger) |
| omega-projects-pusher (.service + .path) | files Allen items on aien-dev/omega-projects | medium: token | 1 | READY: `services/omega-projects-pusher.svc`; token not provisioned on this host (queues only); TPM-sealed credential delivery needs Drake's decision (see table 2) |
| cortex-visitors (no unit) | visitor memory, loopback 18096 | medium | 1 | interim under `~/.local/bin/spark-supervisor` (cron @reboot + ensure); READY: `services/cortex-visitors.svc` |
| allen-relay-mailer (no unit) | Allen relay mail (allen-relay) | medium: mail password | 2 | REMAINING: password comes from atlas-vault through `runuser` on stdin; the root helper will not run operator programs; needs `secret` delivery decision |
| allen-science (planned) | science tools, loopback 18113 | medium | 2 | REMAINING: draft from AllenScience, validated when it lands |
| atlas-account-runtime, atlas-ingress | Atlas service account, ingress nft | medium | 4 | REMAINING: oneshot root setup (Type=oneshot, RemainAfterExit); needs a root-oneshot design, not a sandboxed service |
| atlas-private-storage, atlas-forgejo-storage | TPM unlock of LUKS volumes | high: storage keys | 5 | REMAINING: run as root with TPM access by design; out of the sandboxed-service model |
| atlas-forgejo (system) | Forgejo on Spark | medium | 4 | REMAINING: depends on the storage unlock units |
| atlas-max-flux, atlas-max-gemma, atlas-max-lightning | MAX model servers (inactive) | GPU | 6 | REMAINING: GPU services need the exclusive-window procedure; not touched |
| atlas-trueforge-mcp | MCP server (inactive) | low | 3 | REMAINING: inactive; migrate or delete with its owner |
| ollama | model server (vendor unit, not running) | GPU | 6 | REMAINING: GPU; vendor unit |
| spark-cleanup (.service + .timer), spark-cleanup-lowspace (.service + .timer) | disk cleanup as root | medium: deletes files | 4 | REMAINING: root jobs; candidate for a root-oneshot design or root cron |
| restart-resolved | restarts systemd-resolved early in boot | low | 7 | REMAINING: belongs to the distribution's boot order |

### User units (`~/.config/systemd/user`)

| Service | Role | Risk | Order | Status, reason |
| --- | --- | --- | --- | --- |
| cortex | Cortex memory, Rust Axum, 18080 | high: shared memory | 3 | REMAINING: moves only through CortexOmega's cutover plan |
| hermes-gateway | messaging gateway | high: live | 3 | REMAINING: move at a safe point agreed with its owner |
| omp-collab-hub (.service + .timer) | the one collab room (tmux) | high: live room | 3 | REMAINING: never kill the live room; move at a safe point |
| hive-feed, hive-publish | Hive telemetry collector and publisher | low | 2 | REMAINING: low-risk user services, next batch (user-service files need no root) |
| xerj | local search | low | 2 | REMAINING: next batch |
| spark-cockpit, spark-mail | cockpit 18095, local mail 18092 | low | 2 | REMAINING: next batch; spark-mail has known clients |
| conduit | Matrix homeserver | low | 2 | REMAINING: next batch |
| atlas-authelia, atlas-olivetin | Atlas login and ops panel | medium | 3 | REMAINING: after Atlas owner review |
| atlas-repair, atlas-vault-context7, aien-context7-sync (+timer), atlas-harvest (+timer), atlas-forgejo-backup (+timer) | Atlas jobs (several failing) | low | 3 | REMAINING: owner review; failing units first need their failure understood |
| atlas-brain, atlas-cortex-max-encoder, atlas-forgejo, atlas-forgejo-web, atlas-forgejo-storage, atlas-rootless-docker | Atlas (disabled) | n/a | 8 | REMAINING: disabled; delete or migrate with owner |
| aien-mail | webmail, restart loop on an obsolete tailnet IP | low | 2 | REMAINING: fix the address first, then move |
| aien-astrosage, aien-lightning, aien-seat, drake-voice-telegram, drake-voice-web, forgejo-runner, gideon-bot, gamemoded | disabled or ad hoc | n/a | 8 | REMAINING: disabled; owner decides |
| nvpair, openclaw-heartbeat, radicle-node, spark-dream, spark-muse-bridge, spark-runner | assorted (radicle-node restart loop) | low | 2 | REMAINING: next batch after owner check |
| spark-worker-L*, run-u*, probe-tfs-* | transient `systemd-run` units, all failed | n/a | n/a | REMAINING: transient; stop creating them (use aien-supervise oneshots); `systemctl --user reset-failed` clears them |

Order: 1 = Allen (new services first), 2 = low-risk user services, 3 = live or owned elsewhere,
4..8 = root jobs, storage, GPU, distribution, disabled.

## 2. Allen units: every directive

Mechanism column: B = bwrap argument built by aien-supervise-root, S = setpriv, F = seccomp
filter generated in Omega, C = cgroup v2 leaf, N = nftables table, P = prlimit on the helper,
D = daemon (aien-supervise), W = aien-watch.
Probe column: `tests/probe.py` check name (run by `tests/sandbox.sh`: confined in the sandbox) and
its negative control: U = reads `open` when the same probe runs as the same user without the
sandbox, M = reads `open` when that one directive is removed from the service file (mutation in
`tests/sandbox.sh`), K = the kernel also refuses it to any unprivileged process, so only the
filter result itself is shown. Allen's own probes were rerun in each service's exact sandbox with
`tests/twin.sh` (results under "Allen probes").

| Directive (unit) | aien-supervise mechanism | Probe | Negative control |
| --- | --- | --- | --- |
| Type=simple / oneshot (all) | D `type` | user.sh | user.sh |
| ExecStart (all) | D/S/B `exec`, program root-owned (helper refuses others) | sandbox.sh E "exec under /tmp", "symlink" | refusal cases |
| User=, Group= (all) | S `--reuid/--regid`; uid 1..999 | User | K (sandbox.sh E: user root, uid 1000 refused) |
| SupplementaryGroups= (chat, pusher) | S `--groups` from `groups` + checked initgroups | gw probe: create in spool-in/contacts-drop ALLOWED | sandbox.sh E: docker group refused |
| EnvironmentFile= (chat) | B `--setenv` from root-owned file (values never in argv) | (gateway starts with its token) | n/a |
| Environment= (all) | B `--setenv`; empty environment otherwise | Environment | U |
| UMask= (all) | helper umask, inherited | UMask | M |
| Nice= (all) | `nice -n` before setpriv | (ps) | n/a |
| Restart=on-failure, RestartSec=5 (chat) | D `restart`, `backoff 5 300` | user.sh backoff | user.sh |
| TimeoutStartSec= (catalog, contacts, pusher) | D `timeout` (oneshot); W 4th word (watch) | user.sh "oneshot timeout" | user.sh |
| NoNewPrivileges=yes (all) | S `--no-new-privs` | NoNewPrivileges | U |
| CapabilityBoundingSet= (all) | S `--bounding-set=-all`; userns caps dropped by bwrap | CapabilityBoundingSet | U |
| AmbientCapabilities= (all) | S `--ambient-caps=-all --inh-caps=-all` | AmbientCapabilities | K |
| PrivateUsers=yes (all) | B `--unshare-user`, single uid mapping | PrivateUsers | U |
| ProtectProc=invisible, ProcSubset=pid (all) | B `--unshare-pid` + own `/proc` (only own pids visible). ProcSubset=pid: non-pid `/proc` files stay readable, read-only | ProtectProc, gw "count visible pids 2", "~/.ssh via /proc/<pid>/root DENIED" | U. ProcSubset=pid partly: needs Drake's sign-off |
| ProtectSystem=strict (all) | B read-only `/usr`, `/etc`, sandbox root (`--remount-ro /`); nothing else of the host is mounted | ProtectSystem.usr/.etc/.mntns; pusher "write /var/lib DENIED 30" | U |
| ProtectHome=yes (all) | B `/home`, `/root` not mounted | ProtectHome; gw "read ~/.ssh DENIED" | U |
| ReadWritePaths= (all) | B `--bind` (`rw`, only under /var /srv /run) | gw create in spool-in ALLOWED; pusher write spool-status ok | sandbox.sh E "rw outside" refused |
| ReadOnly by strict (catalog dir for chat etc.) | B `--ro-bind` (`ro`) | gw "write spool-status DENIED 30" | U |
| InaccessiblePaths= (chat) | not mounted (only declared paths exist) | gw "read contact store DENIED ENOENT" | U |
| StateDirectory=omega-pusher (pusher) | `rw /var/lib/omega-pusher` (directory already exists, 0700) | pusher "write state dir ok" | n/a |
| PrivateTmp=yes (all) | B private tmpfs `/tmp`, `/var/tmp` | PrivateTmp | U |
| PrivateDevices=yes, DevicePolicy=closed (all) | B `--dev` (null zero full random urandom tty, pts) | PrivateDevices; pusher "/dev/tpmrm0 visible False" | U |
| DeviceAllow=/dev/tpmrm0 (pusher) | none: only PID 1 used it to decrypt the credential | n/a | n/a |
| ImportCredential=omega-projects-token (pusher) | `secret NAME PATH`: root-owned 0600 file bound at /run/credentials/NAME. The host+TPM sealing of systemd-creds is not reproduced | ImportCredential | M. Plain root-only file instead of TPM-sealed: needs Drake's sign-off before the token is provisioned |
| PrivateIPC=yes (contacts, pusher) | B `--unshare-ipc` (all services) | PrivateIPC | U |
| PrivateNetwork=yes (contacts) | B `--unshare-net` (`net none`) | (contacts has no network: AF_UNIX only) | sandbox.sh F uses net none |
| ProtectKernelTunables=yes (all) | B `/proc/sys`, `/proc/sysrq-trigger`, `/proc/irq`, `/proc/bus`, `/proc/fs`, ... read-only; no `/sys` | ProtectKernelTunables.procsys/.sys | U |
| ProtectKernelModules=yes (all) | F init_module/finit_module/delete_module not allowed; no CAP_SYS_MODULE | ProtectKernelModules.init_module | K |
| ProtectKernelLogs=yes (all) | F syslog not allowed; no `/dev/kmsg` | ProtectKernelLogs.kmsg / .syslog | U / K |
| ProtectControlGroups=yes (all) | B cgroup namespace; no `/sys/fs/cgroup` | ProtectControlGroups, Cgroup.namespace | U |
| ProtectClock=yes (all) | F clock_settime/settimeofday/adjtimex/clock_adjtime not allowed | ProtectClock.clock_settime | K |
| ProtectHostname=yes (all) | B uts namespace; F sethostname/setdomainname not allowed | ProtectHostname.utsns / .sethostname | U / K |
| RestrictSUIDSGID=yes (all) | F chmod/fchmod/fchmodat/fchmodat2/openat/mkdirat/mknodat with S_ISUID/S_ISGID -> EPERM; openat2 -> ENOSYS | RestrictSUIDSGID | U |
| RestrictRealtime=yes (all) | F sched_setscheduler FIFO/RR/DEADLINE and sched_setattr -> EPERM; RLIMIT_RTPRIO 0 | RestrictRealtime, .rlimit | K |
| LockPersonality=yes (all) | F personality only 0 or 0xffffffff | LockPersonality | U |
| MemoryDenyWriteExecute=yes (all) | F mmap W+X, mprotect/pkey_mprotect +X, shmat SHM_EXEC -> EPERM (`mdwe yes`) | MemoryDenyWriteExecute.mmap/.mprotect | U, M |
| RestrictNamespaces=yes (catalog, contacts, pusher) | B `--disable-userns`; F unshare, setns, clone with CLONE_NEW* refused, clone3 ENOSYS | RestrictNamespaces.unshare | U, M |
| RestrictAddressFamilies= (all) | F socket/socketpair family allowlist -> EAFNOSUPPORT | RestrictAddressFamilies | U, M |
| SystemCallFilter=@system-service [@mount unshare setns] (all) | F allowlist from the systemd groups (generated, checked against systemd-analyze) | SystemCallFilter.mincore/.landlock/.ptrace | U |
| SystemCallFilter=~@privileged @resources (contacts, pusher) | F `syscalls-deny @privileged @resources` | (removes e.g. setrlimit; contacts .om binary and pusher ran) | n/a |
| SystemCallErrorNumber=EPERM (contacts, pusher) | F `syscall-error eperm`; default kill as systemd | SystemCallFilter.* (EPERM) | sandbox.sh D: kill gives SIGSYS |
| SystemCallArchitectures=native (all) | F non-AArch64 audit arch -> kill | (no 32-bit userland to test) | not run |
| KeyringMode=private (contacts) | keyctl allowed by @system-service as in systemd; session keyring is the service user's own (dedicated uid) | not probed | not run |
| RemoveIPC=yes (pusher) | ipc namespace is discarded with the sandbox | PrivateIPC | U |
| IPAddressDeny=any, IPAddressAllow= (chat) | N skuid allowlist + `net-default drop`; input: `listen` port source sets | IPAddressDeny.outbound; gw "1.1.1.1 / github / LAN timed out", "100.64.0.3:443 connected", "127.0.0.1:18091 connected" | U, M |
| IPAddressAllow/Deny ranges (catalog) | N `allow 127.0.0.53`, `deny` local ranges, `net-default accept` | real catalog run reached GitHub; pusher probe "api.github.com:443 ok" | U |
| MemoryMax= (chat 1G, contacts 128M, pusher 256M) | C memory.max | MemoryMax (64 MiB cap, 128 MiB child OOM-killed) | M |
| TasksMax= (chat 128, contacts 8, pusher 16) | C pids.max | TasksMax | M |
| CPUQuota=200% (chat) | C cpu.max "200000 100000" | CPUQuota (50%: 0.49 s CPU in 1 s with 4 spinners) | M |
| LimitNOFILE=1024 (chat) | P RLIMIT_NOFILE | LimitNOFILE | M |
| StandardOutput/StandardError=journal (all) | D pipe into `state/log/NAME.log`, rotated | user.sh rotation | user.sh |
| After=/Wants=network-online.target (chat, catalog, pusher) | none: a start before the network fails and backs off | n/a | n/a |
| WantedBy= (all) | D starts every service file found (autostart yes); boot via cron @reboot ensure | user.sh ensure | n/a |
| OnBootSec=5min, OnCalendar=daily, Persistent=true (catalog timer) | D `delay 300`, `every 86400`, last success in `st/NAME.last` | user.sh oneshot every | user.sh |
| DirectoryNotEmpty= (contacts path) | W `watch DIR *` (hidden entries ignored) | W ran ingest on drop | n/a |
| PathExistsGlob=spool-in/*.json (pusher path) | W `watch DIR .json` | W | n/a |

Not reproduced, needing Drake's sign-off: ProcSubset=pid (only pids hidden, not the non-pid
`/proc` files, which stay read-only); ImportCredential's TPM sealing (aien-supervise reads a
root-only file). Everything else has a mechanism and a probe; SystemCallArchitectures=native and
KeyringMode=private are implemented but were not probed.

### Allen probes rerun inside the aien-supervise sandboxes (`tests/twin.sh`, 2026-10-26)

* allen-chat, `/tmp/allenchat/gw/probe.py`: same verdicts as the systemd unit's design (home,
  gh, gb10 lock, contact store, spool-status write, sudo, GitHub/1.1.1.1/LAN DENIED; spool-in and
  contacts-drop create, 127.0.0.1:18091, 100.64.0.3:443, AF_NETLINK ALLOWED; 2 visible pids).
* allen-chat, `/tmp/allenchat/gw/test_sandbox.py /usr/bin/busybox` (nested compile sandbox):
  17/17 passed.
* omega-projects-pusher, `/tmp/allenchat/pusher/sandbox_probe.py`: home, /root, contacts,
  /opt, /etc, /var/lib writes, credstore, AF_NETLINK, AF_PACKET, personality, mount, unshare, W+X
  mmap all DENIED; spool-status and state dir writable; api.github.com:443 reachable; 2 pids;
  CapBnd 0, NoNewPrivs 1, Seccomp 2; /dev/tpmrm0 absent.
* allen-catalog: the real `catalog.py` ran in its sandbox and rewrote catalog.txt (34 areas).
* allen-contacts-ingest: not yet probed under aien-supervise (AllenChat's contacts tests are parity
  tests of the binary, not sandbox probes).

## 3. Cutover (per service, by its owner)

1. `sudo -n sh tests/twin.sh SERVICE <the lane's probes>`: same verdicts as under systemd.
2. `sudo systemctl disable --now SERVICE.service` (and its `.path`/`.timer`).
3. Install `services/SERVICE.svc` root-owned 0644 in `/etc/aien-supervise/services/`.
4. `aien-supervise ensure` (or wait one minute for cron), `aien-supervise status SERVICE`.
5. Rerun the probes against the running service; then remove the unit file and `daemon-reload`.

Rollback: `aien-supervise stop SERVICE`, move the `.svc` out, `systemctl enable --now` the unit.
