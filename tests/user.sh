#!/bin/sh
# user.sh: unprivileged behaviour of out/aien-supervise in a scratch state directory: restart with
# backoff, oneshot period, oneshot timeout, start/stop/restart requests, TERM-to-KILL escalation,
# environment/umask/dir, log rotation, refusal of a bad service file, shutdown. No root, no sudo.
#   sh tests/user.sh        prints one line per case and USER PASS|FAIL cases=N fail=N
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
B=$here/out/aien-supervise
[ -x "$B" ] || { echo "user.sh: build first (tools/build.sh)" >&2; exit 2; }
T=$(mktemp -d /tmp/aien-supervise-test.XXXXXX)
export AIEN_SUPERVISE_STATE=$T/state AIEN_SUPERVISE_USERDIR=$T/user AIEN_SUPERVISE_ROOTDIR=$T/root
mkdir -p "$T/user" "$T/root"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $*"; }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
st() { "$B" status "$1" | tail -1; }
cleanup() { "$B" shutdown >/dev/null 2>&1; sleep 3; rm -rf "$T"; }
trap cleanup EXIT

printf 'i=0; while :; do echo "tick $i HOME=${HOME:-unset} umask=$(umask) pwd=$(pwd)"; i=$((i+1)); sleep 1; done\n' > "$T/tick.sh"
printf 'echo crashing; sleep 1; exit 3\n' > "$T/crash.sh"
printf "trap 'echo ignoring TERM' TERM\nwhile :; do sleep 0.2; done\n" > "$T/stubborn.sh"
printf 'i=0; while [ $i -lt 400 ]; do echo line-$i-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; i=$((i+1)); done; sleep 100\n' > "$T/chatty.sh"
printf 'exec /usr/bin/sh %s/tick.sh\nrestart always\nenv HOME=/tmp\numask 0027\ndir /tmp\n' "$T" > "$T/user/ticker.svc"
printf 'exec /usr/bin/sh %s/crash.sh\nrestart on-failure\nbackoff 1 4\n' "$T" > "$T/user/crash.svc"
printf 'exec /usr/bin/true\ntype oneshot\nevery 2\n' > "$T/user/once.svc"
printf 'exec /usr/bin/sleep 100\ntype oneshot\ntimeout 2\n' > "$T/user/slow.svc"
printf 'exec /usr/bin/sh %s/stubborn.sh\nrestart always\nstoptime 2\n' "$T" > "$T/user/stubborn.svc"
printf 'exec /usr/bin/sh %s/chatty.sh\nlog-max 4000\nlog-keep 2\n' "$T" > "$T/user/chatty.svc"
printf 'exec /usr/bin/true\nuser root\n' > "$T/user/sneaky.svc"
printf 'exec /usr/bin/true\nbogus 1\n' > "$T/user/bad.svc"

"$B" ensure; sleep 8
"$B" status | head -1 | grep -q '^daemon running' && ok "ensure started the daemon" || bad "daemon not running"
"$B" ensure; [ "$(pgrep -fc "$B run")" = 1 ] && ok "second ensure is a no-op" || bad "ensure started a second daemon"
grep -q 'tick 1 HOME=/tmp umask=0027 pwd=/tmp' "$T/state/log/ticker.log" && ok "env, umask and dir applied" || bad "ticker env/umask/dir: $(tail -1 "$T/state/log/ticker.log")"
c=$(grep -c 'crash exited status=3' "$T/state/daemon.log")
grep -q 'crash backoff next_in_s=4' "$T/state/daemon.log" && [ "$c" -ge 3 ] && ok "on-failure restart with backoff 1,2,4 (exits=$c)" || bad "crash backoff: $(grep crash "$T/state/daemon.log" | tr '\n' ';')"
r=$(grep -c 'once exited status=0' "$T/state/daemon.log"); [ "$r" -ge 3 ] && ok "oneshot every 2 s ran $r times" || bad "oneshot ran $r times"
grep -q 'slow timeout, stopping' "$T/state/daemon.log" && st slow | grep -q 'state=failed' && ok "oneshot timeout -> SIGTERM, state failed" || bad "slow: $(st slow)"
st sneaky | grep -q 'state=error' && ok "sandbox key in a user service refused" || bad "sneaky: $(st sneaky)"
st bad | grep -q 'state=error' && ok "unknown key refused" || bad "bad: $(st bad)"
"$B" stop ticker | grep -q 'state=stopped' && ok "stop request" || bad "stop: $(st ticker)"
"$B" start ticker | grep -q 'state=running' && ok "start request" || bad "start: $(st ticker)"
p1=$(st ticker | sed 's/.* pid=\([0-9]*\).*/\1/'); "$B" restart ticker >/dev/null; sleep 1
p2=$(st ticker | sed 's/.* pid=\([0-9]*\).*/\1/'); [ "$p1" != "$p2" ] && st ticker | grep -q state=running && ok "restart request (pid $p1 -> $p2)" || bad "restart: $p1 -> $p2"
"$B" stop stubborn >/dev/null; sleep 3
st stubborn | grep -q 'last=signal:9' && grep -q 'stubborn stop timeout, killing' "$T/state/daemon.log" && ok "TERM ignored -> SIGKILL after stoptime" || bad "stubborn: $(st stubborn)"
[ -f "$T/state/log/chatty.log.1" ] && ok "log rotated at log-max (chatty.log.1 exists)" || bad "no rotation: $(ls "$T/state/log")"
"$B" stop nosuch >/dev/null 2>&1; [ $? != 0 ] && ok "request for unknown service fails" || bad "unknown service request succeeded"
"$B" shutdown; sleep 4
"$B" status | head -1 | grep -q 'not running' && ! pgrep -f "$T/tick.sh" >/dev/null && ok "shutdown stops services and daemon" || bad "after shutdown: $("$B" status | head -1)"
if [ $fail = 0 ]; then v=PASS; else v=FAIL; fi
echo "USER $v cases=$((pass+fail)) fail=$fail"
[ $fail = 0 ]
