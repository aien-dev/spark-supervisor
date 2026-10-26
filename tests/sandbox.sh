#!/bin/sh
# sandbox.sh: qualify the installed aien-supervise-root sandbox on this host. Root only:
#   sudo -n sh tests/sandbox.sh
# Needs: the helper and aien-watch installed under /usr/local/libexec/aien-supervise, the system
# user aien-sup-test (useradd --system --no-create-home --shell /usr/sbin/nologin aien-sup-test),
# python3.12. It writes only /etc/aien-supervise/services/sup-*.svc, /etc/aien-supervise/test-secret,
# /opt/aien-sup-test and /tmp/aien-sup-hostmarker, removes them afterwards, and touches no other
# service. Prints one line per case and SANDBOX PASS|FAIL cases=N fail=N not_run=N.
set -u
here=$(cd "$(dirname "$0")" && pwd)
H=/usr/local/libexec/aien-supervise/aien-supervise-root
S=/etc/aien-supervise/services
T=/opt/aien-sup-test
[ "$(id -u)" = 0 ] || { echo "sandbox.sh: run as root" >&2; exit 2; }
id aien-sup-test >/dev/null 2>&1 || { echo "SANDBOX NOT_RUN: user aien-sup-test missing"; exit 3; }
U=$(id -u aien-sup-test); G=$(id -g aien-sup-test)
pass=0; fail=0; notrun=0
ok() { pass=$((pass+1)); echo "PASS $*"; }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
nr() { notrun=$((notrun+1)); echo "NOT_RUN $*"; }
cleanup() {
  rm -f "$S"/sup-*.svc /etc/aien-supervise/test-secret /tmp/aien-sup-hostmarker
  rm -rf "$T"
  for t in $(nft list tables 2>/dev/null | awk '$3 ~ /^aiens_sup_/ {print $3}'); do nft delete table inet "$t"; done
  for c in /sys/fs/cgroup/aien-supervise/sup-*; do [ -d "$c" ] && rmdir "$c" 2>/dev/null; done
}
trap cleanup EXIT

install -d -o root -g root -m 0755 "$T"
install -o root -g root -m 0644 "$here/probe.py" "$T/probe.py"
for ns in ipc uts pid cgroup mnt; do echo "$ns $(readlink /proc/1/ns/$ns)"; done > "$T/hostns"
chmod 0644 "$T/hostns"
( umask 077; echo s3cret-probe > /etc/aien-supervise/test-secret )
touch /tmp/aien-sup-hostmarker
listen=$(ss -ltnH 'sport = :18096' | wc -l)

base() {
  cat <<EOF
exec /usr/bin/python3.12 -I $T/probe.py $U 512 0027 64 $T/hostns
type oneshot
restart no
user aien-sup-test
env PROBE_ENV=set
umask 0027
ro $T
secret probe-secret /etc/aien-supervise/test-secret
net filter
allow 127.0.0.1
net-default drop
memory-max 67108864
memory-swap-max 0
tasks-max 16
cpu-quota 50
nofile 512
namespaces no
syscalls @system-service
syscall-error eperm
families unix inet inet6
mdwe yes
EOF
}
put() { cat > "$S/$1.svc"; chmod 0644 "$S/$1.svc"; chown root:root "$S/$1.svc"; }
check_open() { grep -q "^CHECK $1 open" "$2"; }

# A. Full sandbox: every check confined.
base | put sup-probe
"$H" run sup-probe > /tmp/sup-a.out 2>&1; rc=$?
if [ $rc = 0 ] && grep -q '^PROBE CONFINED' /tmp/sup-a.out; then ok "A sandbox: $(grep '^PROBE' /tmp/sup-a.out)"; else bad "A sandbox rc=$rc: $(grep -E ' open |^PROBE|aien-supervise-root' /tmp/sup-a.out | tr '\n' ';')"; fi
[ "$listen" -gt 0 ] || nr "A IPAddressAllow.loopback: nothing listens on 127.0.0.1:18096 (check reads open)"
if nft list table inet aiens_sup_probe 2>/dev/null | grep -q "meta skuid $U ip daddr 127.0.0.1 accept"; then ok "A nft table aiens_sup_probe holds the skuid allow rule"; else bad "A nft table missing"; fi

# B. Control: same probe, same user, no sandbox. Every kind-d check must read open. The rules of
# run A are keyed by this uid, so its table is dropped first (one uid per service is the contract).
nft delete table inet aiens_sup_probe 2>/dev/null
setpriv --reuid="$U" --regid="$G" --clear-groups -- /usr/bin/python3.12 -I "$T/probe.py" "$U" 512 0027 64 "$T/hostns" > /tmp/sup-b.out 2>&1
miss=$(awk '$1=="CHECK" && $4=="d" && $3!="open" {print $2}' /tmp/sup-b.out | tr '\n' ' ')
n=$(awk '$1=="CHECK" && $4=="d"' /tmp/sup-b.out | wc -l)
if [ -z "$miss" ] && [ "$n" -gt 30 ]; then ok "B control: all $n kind-d checks read open without the sandbox"; else bad "B control: kind-d checks not open without sandbox: $miss (n=$n)"; fi

# C. One directive weakened at a time: its check must read open.
mut() { # name check sed-expression
  base | sed "$3" | put sup-mut
  "$H" run sup-mut > /tmp/sup-c.out 2>&1
  if check_open "$2" /tmp/sup-c.out; then ok "C $1 removed -> $2 open"; else bad "C $1 removed but $2 not open: $(grep "CHECK $2 " /tmp/sup-c.out)"; fi
}
mut memory-max MemoryMax '/^memory-max/d'
mut tasks-max TasksMax '/^tasks-max/d'
mut cpu-quota CPUQuota '/^cpu-quota/d'
mut mdwe MemoryDenyWriteExecute.mmap 's/^mdwe yes/mdwe no/'
mut namespaces RestrictNamespaces.unshare 's/^namespaces no/namespaces yes/'
mut families RestrictAddressFamilies '/^families/d'
mut nofile LimitNOFILE '/^nofile/d'
mut umask UMask '/^umask/d'
mut secret ImportCredential '/^secret/d'
if python3 -c 'import socket;socket.create_connection(("1.1.1.1",443),2)' 2>/dev/null; then
  nft delete table inet aiens_sup_mut 2>/dev/null
  mut net IPAddressDeny.outbound 's/^net filter/net host/'
else nr "C net: host has no route to 1.1.1.1:443, cannot show the open case"; fi

# D. syscall-error kill: the first denied syscall ends the probe with SIGSYS (31).
base | sed 's/^syscall-error eperm/syscall-error kill/' | put sup-kill
"$H" run sup-kill > /tmp/sup-d.out 2>&1; rc=$?
if [ $rc = 159 ] || [ $rc = 31 ]; then ok "D syscall-error kill: probe ended with status $rc (SIGSYS)"; else bad "D syscall-error kill: rc=$rc"; fi

# E. Refusals: exit 2, nothing ran (no PROBE line).
refuse() { # label svc-name
  "$H" run "$2" > /tmp/sup-e.out 2>&1; rc=$?
  if [ $rc = 2 ] && ! grep -q '^PROBE' /tmp/sup-e.out; then ok "E refused: $1 ($(tr '\n' ' ' < /tmp/sup-e.out | cut -c1-90))"; else bad "E not refused: $1 rc=$rc"; fi
}
base | put sup-r1; chmod 0664 "$S/sup-r1.svc"; refuse "group-writable service file" sup-r1
base | put sup-r2; chown aien-sup-test "$S/sup-r2.svc"; refuse "service file not root-owned" sup-r2
base | sed 's/^user aien-sup-test/user root/' | put sup-r3; refuse "user root" sup-r3
base | sed "s/^user aien-sup-test/user $(id -un 1000)/" | put sup-r4; refuse "uid 1000 operator account" sup-r4
base | sed '$a groups docker' | put sup-r5; refuse "supplementary group docker" sup-r5
cp /usr/bin/true /tmp/sup-true; chmod 0755 /tmp/sup-true
base | sed 's|^exec .*|exec /tmp/sup-true|' | put sup-r6; refuse "exec under world-writable /tmp" sup-r6
base | sed 's|^exec /usr/bin/python3.12|exec /usr/bin/python3|' | put sup-r7; refuse "exec through a symlink" sup-r7
base | sed '$a rw /etc/aien-supervise' | put sup-r8; refuse "rw outside /var /srv /run" sup-r8
base | sed '$a ro /home/drakestapleton' | put sup-r9; refuse "ro under /home" sup-r9
base | sed '$a bogus-key 1' | put sup-r10; refuse "unknown key" sup-r10
base | sed '/^syscalls/d' | put sup-r11; refuse "no syscalls line" sup-r11
base | sed '$a env LD_PRELOAD=/tmp/x.so' | put sup-r12; refuse "LD_ environment" sup-r12
base | sed '$a ro /opt/../etc' | put sup-r13; refuse "path with .." sup-r13
base | sed '$a allow 1.2.3.4;flush' | put sup-r14; refuse "nft injection in allow" sup-r14
refuse "missing service file" sup-none
"$H" run ../etc/x > /tmp/sup-e.out 2>&1; [ $? = 2 ] && ok "E refused: bad name ../etc/x" || bad "E bad name accepted"
"$H" run Sup-Probe > /tmp/sup-e.out 2>&1; [ $? = 2 ] && ok "E refused: upper-case name" || bad "E upper-case name accepted"
setpriv --reuid="$U" --regid="$G" --clear-groups -- "$H" run sup-probe > /tmp/sup-e.out 2>&1; rc=$?
[ $rc = 2 ] && grep -q 'must run as root' /tmp/sup-e.out && ok "E refused: non-root caller" || bad "E non-root caller rc=$rc"
rm -f /tmp/sup-true

# F. Lifecycle: a long-running service; a second run is refused while it runs; stop (SIGTERM to the
# cgroup) ends it; kill (cgroup.kill) ends a TERM-ignoring one.
printf 'exec /usr/bin/sleep 300\nuser aien-sup-test\nsyscalls @system-service\nnet none\n' | put sup-life
"$H" run sup-life > /tmp/sup-f.out 2>&1 & bg=$!
sleep 1
if grep -q '^populated 1' /sys/fs/cgroup/aien-supervise/sup-life/cgroup.events; then ok "F running service is in cgroup aien-supervise/sup-life"; else bad "F cgroup not populated"; fi
"$H" run sup-life > /tmp/sup-f2.out 2>&1; rc=$?
[ $rc = 2 ] && grep -q 'already running' /tmp/sup-f2.out && ok "F second run refused while running" || bad "F second run rc=$rc"
"$H" stop sup-life; wait $bg; rc=$?
[ $rc = 143 ] && ok "F stop: service ended by SIGTERM (status 143)" || bad "F stop: status $rc"
printf 'exec /usr/bin/python3.12 -I %s/ignterm.py\nuser aien-sup-test\nsyscalls @system-service\nro %s\n' "$T" "$T" | put sup-life
printf 'import signal, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\ntime.sleep(300)\n' > "$T/ignterm.py"; chmod 0644 "$T/ignterm.py"
"$H" run sup-life > /tmp/sup-f.out 2>&1 & bg=$!
sleep 1.5
"$H" stop sup-life; sleep 1
if kill -0 $bg 2>/dev/null; then ok "F TERM-ignoring service survives stop"; else bad "F TERM-ignoring service ended on stop"; fi
"$H" kill sup-life; rc_k=$?; wait $bg; rc=$?
[ $rc_k = 0 ] && [ $rc = 137 ] && ok "F kill: cgroup.kill ended it (status 137)" || bad "F kill: helper rc=$rc_k status=$rc"

total=$((pass+fail+notrun))
if [ $fail = 0 ]; then v=PASS; else v=FAIL; fi
echo "SANDBOX $v cases=$total pass=$pass fail=$fail not_run=$notrun"
[ $fail = 0 ]
