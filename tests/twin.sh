#!/bin/sh
# twin.sh: run an isolation probe inside an installed service's exact sandbox. Root only:
#   sudo -n sh tests/twin.sh SERVICE PROBE.py [ARGS...] [-- EXTRA_FILE...]
# Copies /etc/aien-supervise/services/SERVICE.svc to SERVICE-twin.svc with only these changes:
# the exec line runs `python3.12 -I /opt/aien-sup-twin/PROBE.py ARGS`, watch/restart/type lines
# become `type oneshot` + `restart no`, and /opt/aien-sup-twin is bound read-only. User, groups,
# binds, network rules, cgroup limits and the syscall filter are the service's own. The probe and
# any EXTRA_FILE are copied into /opt/aien-sup-twin (root-owned). The twin's nftables table (same
# uid rules as the service) and the twin file are removed afterwards. Exit status: the probe's.
set -u
[ "$(id -u)" = 0 ] || { echo "twin.sh: run as root" >&2; exit 2; }
[ $# -ge 2 ] || { echo "usage: twin.sh SERVICE PROBE.py [ARGS...] [-- EXTRA_FILE...]" >&2; exit 2; }
svc=$1; probe=$2; shift 2
S=/etc/aien-supervise/services
D=/opt/aien-sup-twin
H=/usr/local/libexec/aien-supervise/aien-supervise-root
[ -f "$S/$svc.svc" ] || { echo "twin.sh: no $S/$svc.svc" >&2; exit 2; }
args=""; extra=""; inextra=0
for a in "$@"; do
  if [ "$a" = -- ]; then inextra=1; continue; fi
  if [ $inextra = 1 ]; then extra="$extra $a"; else args="$args $a"; fi
done
install -d -o root -g root -m 0755 "$D"
install -o root -g root -m 0644 "$probe" "$D/$(basename "$probe")"
for f in $extra; do install -o root -g root -m 0644 "$f" "$D/$(basename "$f")"; done
twin=$svc-twin
trap 'rm -f "$S/$twin.svc"; nft delete table inet "aiens_$(echo "$twin" | tr - _)" 2>/dev/null; rm -rf "$D"' EXIT
{
  grep -vE '^(exec|watch|restart|type|every|delay|timeout) ' "$S/$svc.svc"
  echo "exec /usr/bin/python3.12 -I $D/$(basename "$probe")$args"
  echo "type oneshot"
  echo "restart no"
  echo "ro $D"
} > "$S/$twin.svc"
chmod 0644 "$S/$twin.svc"
"$H" run "$twin"
