#!/usr/bin/python3.12 -I
"""Sandbox probe for aien-supervise (test oracle, not part of the supervisor).

Run inside a service sandbox it reports, for each systemd directive the sandbox replaces, whether the
process is confined. tests/sandbox.sh runs it three ways:
  * under `aien-supervise-root run sup-probe`: every check must read `confined`;
  * as the same user without the sandbox: every kind-d check must read `open`, which proves the
    probe can see the property missing;
  * under service files with one directive weakened: the matching check must read `open`.
Kind k checks are refused by the kernel to any unprivileged process as well; their negative
control is the per-directive mutation only. Python because these checks need raw syscalls that
Omega deliberately does not expose.

usage: probe.py UID NOFILE UMASK MEMMAX_MB HOSTNS_FILE
"""
import ctypes, errno, mmap, os, socket, sys, time, threading, resource

libc = ctypes.CDLL("libc.so.6", use_errno=True)
libc.syscall.restype = ctypes.c_long
results = []


def report(name, confined, detail="", kind="d"):
    results.append((name, confined))
    print(f"CHECK {name} {'confined' if confined else 'open'} {kind} {detail}".rstrip(), flush=True)


def sc(nr, *args):
    ctypes.set_errno(0)
    r = libc.syscall(ctypes.c_long(nr), *[ctypes.c_long(a) for a in args])
    return r, ctypes.get_errno()


def status_field(key):
    for line in open("/proc/self/status"):
        if line.startswith(key + ":"):
            return line.split(":", 1)[1].strip()
    return ""


def denied(nr, *args, want=errno.EPERM):
    r, e = sc(nr, *args)
    return r == -1 and e == want, f"r={r} errno={errno.errorcode.get(e, e)}"


def readonly_mount(path):
    return bool(os.statvfs(path).f_flag & os.ST_RDONLY)


uid, nofile, want_umask, memmax_mb, hostns = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3], 8), int(sys.argv[4]), sys.argv[5]
host = dict(l.split() for l in open(hostns)) if os.path.exists(hostns) else {}

# Identity and privileges: User=, NoNewPrivileges=, CapabilityBoundingSet=, AmbientCapabilities=
report("User", os.getuid() == uid and os.geteuid() == uid and uid != 0, f"uid={os.getuid()}", "k")
report("NoNewPrivileges", status_field("NoNewPrivs") == "1")
report("CapabilityBoundingSet", int(status_field("CapBnd"), 16) == 0, "CapBnd=" + status_field("CapBnd"))
report("AmbientCapabilities", int(status_field("CapAmb"), 16) == 0 and int(status_field("CapInh"), 16) == 0, "", "k")
report("SystemCallFilter.active", status_field("Seccomp") == "2", "Seccomp=" + status_field("Seccomp"))

# PrivateUsers=: a user namespace with a single uid mapping (bwrap's --disable-userns adds a
# nested namespace, so the outside id shown is that of the intermediate one)
um = open("/proc/self/uid_map").read().split()
report("PrivateUsers", len(um) == 3 and um[0] == str(uid) and um[2] == "1", " ".join(um))

# Namespaces differ from the host's
for ns, directive in (("ipc", "PrivateIPC"), ("uts", "ProtectHostname.utsns"), ("pid", "ProtectProc.pidns"),
                      ("cgroup", "ProtectControlGroups.cgroupns"), ("mnt", "ProtectSystem.mntns")):
    mine = os.readlink(f"/proc/self/ns/{ns}")
    report(directive, bool(host) and mine != host.get(ns), mine)

# Filesystem: ProtectSystem=strict, ProtectHome=, PrivateTmp=, PrivateDevices=, ProtectKernel*
report("ProtectSystem.usr", readonly_mount("/usr"))
report("ProtectSystem.etc", readonly_mount("/etc"))
report("ProtectHome", not os.path.exists("/home") and not os.path.exists("/root"))
report("PrivateTmp", not os.path.exists("/tmp/aien-sup-hostmarker"))
report("PrivateDevices", not any(os.path.exists(p) for p in ("/dev/nvme0n1", "/dev/sda", "/dev/mem", "/dev/nvidia0", "/dev/tpmrm0")) and os.path.exists("/dev/null"))
report("ProtectKernelTunables.sys", not os.path.exists("/sys/kernel"))
report("ProtectKernelTunables.procsys", readonly_mount("/proc/sys"))
report("ProtectControlGroups", not os.path.exists("/sys/fs/cgroup/cgroup.controllers"))
npids = len([p for p in os.listdir("/proc") if p.isdigit()])
report("ProtectProc", npids < 20, f"pids={npids}")
report("ProtectKernelLogs.kmsg", not os.path.exists("/dev/kmsg"))

# Syscall filter. Numbers are Linux ARM64.
buf = mmap.mmap(-1, 4096)
addr = ctypes.addressof(ctypes.c_char.from_buffer(buf))
vec = ctypes.create_string_buffer(1)
c, d = denied(232, addr, 4096, ctypes.addressof(vec)); report("SystemCallFilter.mincore", c, d)
c, d = denied(444, 0, 0, 1); report("SystemCallFilter.landlock", c, d)
c, d = denied(117, 16, 999999999, 0, 0); report("SystemCallFilter.ptrace", c, d)
r, e = sc(222, 0, 4096, 3, 0x22, -1, 0)
report("SystemCallFilter.allows_basic_mmap", r > 0, f"r={r}", "k")
c, d = denied(40, 0, 0, 0, 0, 0); report("SystemCallFilter.mount", c, d, "k")
c, d = denied(116, 3, 0, 0); report("ProtectKernelLogs.syslog", c, d, "k")
c, d = denied(105, 0, 0, 0); report("ProtectKernelModules.init_module", c, d, "k")
c, d = denied(112, 0, 0); report("ProtectClock.clock_settime", c, d, "k")
name = ctypes.create_string_buffer(b"probe")
c, d = denied(161, ctypes.addressof(name), 5); report("ProtectHostname.sethostname", c, d, "k")
c, d = denied(97, 0x10000000); report("RestrictNamespaces.unshare", c, d)
c, d = denied(92, 0x0008)
report("LockPersonality", c, d)
sc(92, 0)
r, e = sc(92, 0xffffffff); report("LockPersonality.query_allowed", r >= 0, f"r={r}", "k")
c, d = denied(222, 0, 4096, 7, 0x22, -1, 0); report("MemoryDenyWriteExecute.mmap", c, d)
c, d = denied(226, addr, 4096, 5); report("MemoryDenyWriteExecute.mprotect", c, d)
fn = "/tmp/suid-probe"
open(fn, "w").close()
try:
    os.chmod(fn, 0o4755)
    report("RestrictSUIDSGID", False, "chmod u+s succeeded")
except PermissionError:
    report("RestrictSUIDSGID", True, "EPERM")
os.unlink(fn)
param = ctypes.c_int(1)
c, d = denied(119, 0, 1, ctypes.addressof(param)); report("RestrictRealtime", c, d, "k")
try:
    socket.socket(17, socket.SOCK_RAW)
    report("RestrictAddressFamilies", False, "AF_PACKET opened")
except OSError as ex:
    report("RestrictAddressFamilies", ex.errno == errno.EAFNOSUPPORT, errno.errorcode.get(ex.errno, ""))

# Resources: MemoryMax=, TasksMax=, CPUQuota=, LimitNOFILE=, UMask=
report("LimitNOFILE", resource.getrlimit(resource.RLIMIT_NOFILE)[0] == nofile, str(resource.getrlimit(resource.RLIMIT_NOFILE)))
report("UMask", os.umask(0o022) == want_umask)
report("RestrictRealtime.rlimit", resource.getrlimit(resource.RLIMIT_RTPRIO) == (0, 0), "", "k")
cg = open("/proc/self/cgroup").read().strip()
report("Cgroup.namespace", cg == "0::/", cg)
pid = os.fork()
if pid == 0:
    try:
        b = bytearray(memmax_mb * 2 * 1024 * 1024)
        for i in range(0, len(b), 4096):
            b[i] = 1
        os._exit(0)
    except MemoryError:
        os._exit(3)
_, st = os.waitpid(pid, 0)
report("MemoryMax", os.WIFSIGNALED(st) and os.WTERMSIG(st) == 9, f"wait_status={st}")
kids, refused = [], 0
for _ in range(64):
    try:
        p = os.fork()
    except BlockingIOError:
        refused += 1
        break
    if p == 0:
        time.sleep(2)
        os._exit(0)
    kids.append(p)
for p in kids:
    os.waitpid(p, 0)
report("TasksMax", refused > 0, f"forked={len(kids)}")
stop = time.time() + 1.0


def spin():
    while time.time() < stop:
        pass


t0 = time.process_time()
ts = [threading.Thread(target=spin) for _ in range(4)]
[t.start() for t in ts]
[t.join() for t in ts]
used = time.process_time() - t0
report("CPUQuota", used < 1.0, f"cpu_s={used:.2f} in 1 s wall with 4 spinners")


# Network: IPAddressDeny=/IPAddressAllow= through the per-uid nftables table
def connect(addr, port):
    s = socket.socket()
    s.settimeout(2)
    try:
        s.connect((addr, port))
        return "connected"
    except OSError as ex:
        return type(ex).__name__ + ":" + errno.errorcode.get(ex.errno or 0, "timeout")
    finally:
        s.close()


out = connect("1.1.1.1", 443)
report("IPAddressDeny.outbound", out != "connected", out)
out = connect("127.0.0.1", 18096)
report("IPAddressAllow.loopback", out == "connected", out, "k")

# Descriptors and environment: no leaked memfds; only the declared environment
fds = sorted(int(f) for f in os.listdir("/proc/self/fd"))
report("NoLeakedFds", fds[:3] == [0, 1, 2] and len(fds) <= 4, str(fds), "k")
report("Environment", "HOME" not in os.environ and os.environ.get("PROBE_ENV") == "set", ",".join(sorted(os.environ)))
cred = os.environ.get("CREDENTIALS_DIRECTORY")
try:
    ok = bool(cred) and open(os.path.join(cred, "probe-secret")).read().strip() == "s3cret-probe"
except OSError:
    ok = False
report("ImportCredential", ok, str(cred))

n_open = sum(1 for _, c in results if not c)
print(f"PROBE {'CONFINED' if n_open == 0 else 'OPEN'} checks={len(results)} open={n_open}", flush=True)
