#!/bin/sh
# build.sh: compile the three programs with the pinned seeded Omega compiler.
#   OMC=/path/to/omega-mv/seed/out/omc tools/build.sh
# Each program is lib.om + syscalls.om + <program>.om, compiled by omc from stdin. A refused
# compile stops the build and its partial output is deleted, never kept or run.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
OMC=${OMC:?set OMC to the pinned omega-mv seed/out/omc}
# omega-mv 0d6af54f995ffda3a4a07e06da8cd5e343f647f9 (2026-10-26), seed/out/omc:
pin=befb8199db8c4bca188a494dfaac2a6f0ee5c36fcea11188c75666c55fce8a1d
got=$(sha256sum "$OMC" | cut -d' ' -f1)
if [ "$got" != "$pin" ] && [ "${OMC_ANY:-}" != 1 ]; then
  echo "build: omc sha256 $got is not the pin $pin (set OMC_ANY=1 to build anyway)" >&2
  exit 2
fi
mkdir -p "$here/out"
for p in supervise root watch; do
  case $p in supervise) bin=aien-supervise ;; root) bin=aien-supervise-root ;; watch) bin=aien-watch ;; esac
  if cat "$here/om/lib.om" "$here/om/syscalls.om" "$here/om/$p.om" | "$OMC" > "$here/out/$bin.new" 2> "$here/out/$bin.err"; then
    chmod 0755 "$here/out/$bin.new"
    mv -f "$here/out/$bin.new" "$here/out/$bin"
    rm -f "$here/out/$bin.err"
    echo "built out/$bin $(sha256sum "$here/out/$bin" | cut -d' ' -f1)"
  else
    rc=$?
    rm -f "$here/out/$bin.new"
    echo "build: omc refused om/$p.om (rc=$rc):" >&2
    cat "$here/out/$bin.err" >&2
    exit 1
  fi
done
