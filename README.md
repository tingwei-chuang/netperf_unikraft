# netperf on Unikraft

A port of **netserver** (the listening side of the netperf benchmark suite) to
the [Unikraft](https://unikraft.org) unikernel framework. The host-side
`netperf` client drives tests against the unikernel over either virtio-net
(plain TCP) or AF_VSOCK (vsock-enabled build).

| | |
| --- | --- |
| Source release | netperf **2.7.0** (HewlettPackard/netperf) |
| Unikraft tree   | based on 0.21.0 (Ijiraq), patched (see [Porting story](#porting-story)) |
| Tests verified  | TCP_STREAM, TCP_RR, UDP_STREAM, UDP_RR |
| Image size      | ~1.5 MB stripped |
| Boot to listen  | ~0.13 s (TCG x86), ~0.06 s (KVM), several seconds (TCG arm64) |

## Build modes at a glance

| Mode | Target | Transport | Helper script | Image path |
| --- | --- | --- | --- | --- |
| **x86_64 TCP** | `qemu-system-x86_64`, KVM-friendly | virtio-net + lwIP | `make` from `apps/netperf/` | `apps/netperf/build/netperf_qemu-x86_64` |
| **arm64 TCP** | `qemu-system-aarch64 -M virt` | virtio-net + lwIP | `apps/netperf/build_arm64.sh` | `apps/netperf/build-arm64/netperf_qemu-arm64` |
| **arm64 vsock** | `qemu-system-aarch64 -M virt` | virtio-vsock (mmio) | `apps/netperf/build_vsock.sh` | `apps/netperf/build-vsock/netperf_qemu-arm64` |

All three build into separate directories — switching modes does not require a
clean build.

### Why is there no x86_64 vsock build?

`virtio-vsock` is a **modern-only** virtio device (PCI device id `0x1053`).
Unikraft's `virtio-pci` driver is **legacy-only** (it rejects ids outside
`0x1000-0x103f`), so a vsock device on the x86 `pc` PCI bus cannot be probed.
arm64's `virt` machine exposes virtio-mmio buses, and virtio-mmio supports
modern devices — so vsock works there. The same workaround is used by
[`unikraft/app-iperf3`](https://github.com/unikraft/app-iperf3) — see
[Vsock notes](#vsock-notes) for the full design.

### What each "feature" knob means at build time

| Feature toggle | Compile-time or runtime? | How to flip |
| --- | --- | --- |
| TCP transport vs. vsock transport | **Build time** | Use the TCP defconfig (`netperf.{,arm64.}defconfig`) vs. the vsock defconfig (`netperf.arm64.vsock.defconfig`). The vsock shim is unconditional once `CONFIG_LIBUKVSOCKDEV=y` is set — every `AF_INET` TCP socket transparently becomes `AF_VSOCK`. |
| `vhost-net` on / off (TCP only) | **Runtime** (QEMU flag) | `-netdev tap,...,vhost=on` vs. `vhost=off`. Same guest image either way. |
| `vhost-vsock` on / off | **Not available** | QEMU's `vhost-vsock-pci` / `vhost-vsock-device` is the *only* vsock backend — there is no userspace virtio-vsock implementation to compare against. The vsock data point is single-valued. |
| OMNI test engine (TCP_STREAM/TCP_RR/UDP_*) | **Build time** | `CONFIG_APPNETPERF_USE_OMNI=y` (default y). Without it only legacy BSD tests are built. |
| Boot debug log | **Build time** | `CONFIG_LIBUKPRINT_KLVL_INFO` (info, default) vs. `CONFIG_LIBUKPRINT_KLVL_DEBUG` (very verbose; slows TCG ~10x). |

## Verified results

x86 (host: Intel, WSL2, TCG, single vcpu):

| Test                 | x86_64 user-mode | x86_64 tap+vhost   |
| -------------------- | ---------------: | -----------------: |
| TCP_STREAM 1 KB msg  |         443 Mbps |     **4156 Mbps**  |
| TCP_STREAM 8 KB msg  |        1439 Mbps |     **3357 Mbps**  |
| TCP_STREAM 64 KB msg |         548 Mbps |     **3450 Mbps**  |
| TCP_RR 1 KB req/resp |   2630 trans/sec |  **7179 trans/sec**|

arm64 (cross-compiled, run under TCG on an x86 host):

| Test                 | arm64 tap+vhost (TCP) | arm64 vsock (via socat) |
| -------------------- | --------------------: | ----------------------: |
| TCP_STREAM 1 KB msg  |        **2813 Mbps**  |               265 Mbps  |
| TCP_RR  1 B  req/resp |                    — |        **3609 trans/sec** |

The arm64 numbers are TCG-limited (CPU emulation dominates). On real arm64
hardware with KVM these will be much higher; the same image runs unchanged —
see [Running on real arm64 with KVM](#running-on-real-arm64-with-kvm).

## Prerequisites

Host tools:

```bash
# Common
sudo apt-get install -y git patch wget build-essential bison flex \
                        libncurses-dev python3 unzip netperf

# x86_64 host build / native run
sudo apt-get install -y qemu-system-x86

# arm64 cross-compile and QEMU
sudo apt-get install -y gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
                        qemu-system-arm

# Vsock-only: socat 1.7.4+ for the host TCP↔vsock bridge
sudo apt-get install -y socat
```

For vsock you also need `/dev/vhost-vsock` accessible and the `vhost_vsock`
kernel module loaded:

```bash
sudo modprobe vhost_vsock
sudo chmod a+rw /dev/vhost-vsock   # or add your user to the kvm group
```

For tap-based TCP runs (recommended for benchmarking) the usual one-time
tap0 / vhost-net setup:

```bash
sudo ip tuntap add dev tap0 mode tap user "$USER"
sudo ip addr add 172.31.0.1/24 dev tap0
sudo ip link set dev tap0 up
sudo modprobe vhost_net
sudo chmod a+rw /dev/vhost-net
```

## Setup

```bash
git clone <this-repo> netperf_unikraft
cd netperf_unikraft
./setup.sh
```

`setup.sh` clones Unikraft + lwIP + musl + compiler-rt at pinned SHAs and
applies the two upstream patches under `patches/`. It is idempotent — safe to
re-run.

> Note: the vsock build uses a *separate* vendored Unikraft tree under
> `unikraft-vsock/` (the same kernel `unikraft/app-iperf3` uses, with vsock
> support). It is committed to the repo, not cloned, so `setup.sh` does not
> touch it.

## Building

### x86_64 (TCP)

```bash
cd apps/netperf
cp netperf.defconfig .config
make olddefconfig
make -j$(nproc)
# image: build/netperf_qemu-x86_64
```

### arm64 (TCP) — cross-compile from x86 host

```bash
./apps/netperf/build_arm64.sh
# image: apps/netperf/build-arm64/netperf_qemu-arm64
```

The script wires up `CROSS_COMPILE=aarch64-linux-gnu-` and `O=build-arm64` so
it does not collide with the x86 build.

### arm64 + vsock — cross-compile from x86 host

```bash
./apps/netperf/build_vsock.sh
# image: apps/netperf/build-vsock/netperf_qemu-arm64
```

This uses the vsock-enabled kernel under `unikraft-vsock/` and the
`netperf.arm64.vsock.defconfig`. Output goes to `build-vsock/` so it does not
collide with either TCP build.

## Running and benchmarking

The unikernel is the `netserver` (server side). The matching client is the
stock `netperf` binary on the host (`apt-get install netperf`); every
`netperf` command below runs on the **host**, not in the guest.

Pick the row that matches what you want to measure. Each mode works on both
x86_64 and arm64 unless noted.

| Mode | Transport | Host setup | What it isolates | Throughput |
| --- | --- | --- | --- | --- |
| [1](#mode-1--user-mode-networking-slirp--ip-forwarding) | QEMU user-mode (slirp `hostfwd`) | None | Slirp + per-packet QEMU userspace copy | Lowest |
| [2](#mode-2--tap--virtio-net-software-vhostoff) | Tap + virtio-net, `vhost=off` | `tap0` | Pure software virtio data path in QEMU userspace | Medium |
| [3](#mode-3--tap--virtio-net-kernel-accelerated-vhoston) | Tap + virtio-net, `vhost=on` | `tap0` + `vhost-net` | Kernel `vhost-net` accelerated data path | Highest TCP |
| [4](#mode-4--vsock-arm64-only) | vsock over virtio-mmio (`vhost-vsock`) | `vhost-vsock` + 2× socat bridges | `AF_VSOCK` transport, always vhost | High (always vhost) |

Mode 4 is arm64-only — Unikraft's legacy-only virtio-pci driver can't probe
the modern-only virtio-vsock device on x86's `pc` bus. See [Vsock notes](#vsock-notes).

For what every `netperf` flag means and which test type measures what, jump to
[netperf command reference](#netperf-command-reference).

---

### Mode 1 — User-mode networking (slirp / IP forwarding)

QEMU's built-in user-mode stack ("slirp") gives the guest DHCP, NAT and a
default gateway entirely in QEMU userspace. No tap, no root, no host network
config. The cost is throughput — every packet is copied through slirp.

Both the control connection (12865) and the OMNI data connection need a
host-side TCP forward. The data port is ephemeral by default, so we pin it
with `-P ,<port>` on the client and add a matching `hostfwd` to QEMU.

**x86_64**

```bash
qemu-system-x86_64 -display none -no-reboot -nographic \
  -kernel apps/netperf/build/netperf_qemu-x86_64 \
  -m 256 -cpu max \
  -netdev user,id=hn0,hostfwd=tcp::20003-:12865,hostfwd=tcp::12866-:12866 \
  -device virtio-net-pci,netdev=hn0 \
  -append "netperf -- -D -f -4 -p 12865"
```

**arm64** — same idea, different QEMU binary. Runs under TCG on an x86 host
(slow); add `-enable-kvm -cpu host` on a real arm64 host (see
[Running on real arm64 with KVM](#running-on-real-arm64-with-kvm)).

```bash
qemu-system-aarch64 -M virt -cpu max -display none -no-reboot -nographic \
  -kernel apps/netperf/build-arm64/netperf_qemu-arm64 \
  -m 256 \
  -netdev user,id=hn0,hostfwd=tcp::20003-:12865,hostfwd=tcp::12866-:12866 \
  -device virtio-net-pci,netdev=hn0 \
  -append "netperf -- -D -f -4 -p 12865"
```

**Benchmark from the host:**

```bash
# Bulk throughput, host → guest, 1 KB sends, 10 s
netperf -H 127.0.0.1 -p 20003 -t TCP_STREAM -l 10 -- -m 1024 -P ,12866
# Request/response, 1 KB each direction
netperf -H 127.0.0.1 -p 20003 -t TCP_RR     -l 10 -- -r 1024,1024 -P ,12866
# UDP bulk, MTU-sized datagrams
netperf -H 127.0.0.1 -p 20003 -t UDP_STREAM -l 10 -- -m 1400 -P ,12866
```

---

### Mode 2 — Tap + virtio-net, software (`vhost=off`)

A real `tap0` device plumbs the guest into the host bridge / routing table.
The virtio-net device model runs in **QEMU userspace** — packets reach the
host kernel through tap, but per-packet I/O on the ring stays in QEMU.

**One-time host setup:**

```bash
sudo ip tuntap add dev tap0 mode tap user "$USER"
sudo ip addr add 172.31.0.1/24 dev tap0
sudo ip link set dev tap0 up
```

The unikernel takes its IP from the kernel cmdline via `netdev.ip=<cidr>:<gw>`
(enabled by `CONFIG_LIBUKNETDEV_EINFO_LIBPARAM=y`).

**x86_64**

```bash
qemu-system-x86_64 -display none -no-reboot -nographic \
  -kernel apps/netperf/build/netperf_qemu-x86_64 \
  -m 256 -cpu max \
  -netdev tap,id=hn0,ifname=tap0,script=no,downscript=no,vhost=off \
  -device virtio-net-pci,netdev=hn0 \
  -append "netperf netdev.ip=172.31.0.2/24:172.31.0.1 -- -D -f -4 -p 12865"
```

**arm64**

```bash
qemu-system-aarch64 -M virt -cpu max -display none -no-reboot -nographic \
  -kernel apps/netperf/build-arm64/netperf_qemu-arm64 \
  -m 256 \
  -netdev tap,id=hn0,ifname=tap0,script=no,downscript=no,vhost=off \
  -device virtio-net-pci,netdev=hn0 \
  -append "netperf netdev.ip=172.31.0.2/24:172.31.0.1 -- -D -f -4 -p 12865"
```

The arm64 boot log spends ~30 ms listing dummy virtio-mmio slots before the
PCI bus is probed — not an error. Look for `Registered netdev0` and
`liblwip … en1: Set as default interface`.

**Benchmark from the host** — no `-P` needed; the host has a direct route to
the guest IP:

```bash
netperf -H 172.31.0.2 -p 12865 -t TCP_STREAM -l 10 -- -m 1024
netperf -H 172.31.0.2 -p 12865 -t TCP_RR     -l 10 -- -r 1024,1024
netperf -H 172.31.0.2 -p 12865 -t UDP_STREAM -l 10 -- -m 1400
```

---

### Mode 3 — Tap + virtio-net, kernel-accelerated (`vhost=on`)

Same `tap0` setup as Mode 2, but the data path moves into `vhost-net` in the
host kernel. QEMU only programs the rings; per-packet I/O bypasses QEMU
userspace entirely. Best TCP numbers on this stack.

**Extra one-time setup (on top of tap0 from Mode 2):**

```bash
sudo modprobe vhost_net
sudo chmod a+rw /dev/vhost-net
```

**x86_64**

```bash
qemu-system-x86_64 -display none -no-reboot -nographic \
  -kernel apps/netperf/build/netperf_qemu-x86_64 \
  -m 256 -cpu max \
  -netdev tap,id=hn0,ifname=tap0,script=no,downscript=no,vhost=on,vhostforce=on \
  -device virtio-net-pci,netdev=hn0 \
  -append "netperf netdev.ip=172.31.0.2/24:172.31.0.1 -- -D -f -4 -p 12865"
```

**arm64**

```bash
qemu-system-aarch64 -M virt -cpu max -display none -no-reboot -nographic \
  -kernel apps/netperf/build-arm64/netperf_qemu-arm64 \
  -m 256 \
  -netdev tap,id=hn0,ifname=tap0,script=no,downscript=no,vhost=on,vhostforce=on \
  -device virtio-net-pci,netdev=hn0 \
  -append "netperf netdev.ip=172.31.0.2/24:172.31.0.1 -- -D -f -4 -p 12865"
```

**Benchmark from the host** — identical commands to Mode 2; the only
difference between Modes 2 and 3 is QEMU's `vhost=` flag, so A/B-ing them on
the **same image** isolates exactly the cost of moving virtio I/O through
QEMU userspace.

```bash
netperf -H 172.31.0.2 -p 12865 -t TCP_STREAM -l 10 -- -m 1024
netperf -H 172.31.0.2 -p 12865 -t TCP_RR     -l 10 -- -r 1024,1024
netperf -H 172.31.0.2 -p 12865 -t UDP_STREAM -l 10 -- -m 1400
```

---

### Mode 4 — vsock (arm64 only)

A different transport: the unikernel's TCP socket is transparently swapped
to `AF_VSOCK` by a shim in the vendored vsock-enabled Unikraft tree (see
[Vsock notes](#vsock-notes)). The data path goes through `vhost-vsock` in
the host kernel. QEMU ships no userspace vsock backend, so vsock is always
vhost-accelerated — there is no `vhost=off` toggle to compare against.

Stock host `netperf` only speaks TCP, so we run **two `socat` bridges** to
translate: one for the control connection, one for the data connection. The
data port is pinned with `-P ,12866` so the server binds the exact vsock
port the data bridge is forwarding.

**One-time host setup:**

```bash
sudo modprobe vhost_vsock
sudo chmod a+rw /dev/vhost-vsock
sudo apt-get install -y socat
```

**Launch the unikernel** (guest CID 3, control port 12865, data port 12866):

```bash
qemu-system-aarch64 -M virt -cpu max -display none -no-reboot -nographic \
  -kernel apps/netperf/build-vsock/netperf_qemu-arm64 \
  -m 256 \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -device vhost-vsock-device,bus=virtio-mmio-bus.0,guest-cid=3 \
  -append "netperf"
```

A wrapper script `apps/netperf/netperf_vsock.sh` runs the same command.

**Start the two socat bridges** (leave them running, each in its own
terminal):

```bash
# Control bridge:  host TCP 22865 -> guest vsock 3:12865
socat TCP4-LISTEN:22865,bind=127.0.0.1,reuseaddr,fork VSOCK-CONNECT:3:12865

# Data bridge:     host TCP 12866 -> guest vsock 3:12866
socat TCP4-LISTEN:12866,bind=127.0.0.1,reuseaddr,fork VSOCK-CONNECT:3:12866
```

(Control uses host port 22865 instead of 12865 because the host's own
`netserver` service may already hold 12865/tcp.)

**Benchmark from the host** — `-P ,12866` is **mandatory** or the server
picks an ephemeral vsock port the data bridge cannot anticipate:

```bash
netperf -H 127.0.0.1 -p 22865 -t TCP_STREAM -l 10 -- -m 1024 -P ,12866
netperf -H 127.0.0.1 -p 22865 -t TCP_RR     -l 10 -- -r 1024,1024 -P ,12866
```

Even though the test names say `TCP_*`, the **guest** socket is `AF_VSOCK`
end-to-end. The only TCP segments on the wire are between `netperf` and the
host-side `socat`.

---

### Running on real arm64 with KVM

On a real arm64 host with KVM, any of Modes 1–4 above runs unchanged — just
add `-enable-kvm -cpu host` to the QEMU command.

The **vsock defconfig builds in both GICv2 and GICv3** drivers
(`CONFIG_LIBUKINTCTLR_GICV2=y` + `CONFIG_LIBUKINTCTLR_GICV3=y`).
`uk_intctlr_probe()` tries GICv2 first and falls back to GICv3, so the
same image boots under QEMU TCG `-M virt` (GICv2 by default) and on real
arm64 KVM hosts (which almost always expose only GICv3 to guests).

The **arm64 TCP defconfig is still GICv2-only** (inherited from
`KVM_VMM_QEMU`'s `imply LIBUKINTCTLR_GICV2`). On a GICv3-only KVM host
either force GICv2 with `-M virt,gic-version=2` (if your host supports
it) or add `CONFIG_LIBUKINTCTLR_GICV3=y` to
`apps/netperf/netperf.arm64.defconfig` and rebuild.

**Caveat — nested testing under an emulated arm64 host on x86.** The vsock
defconfig sets `CONFIG_LIBUKRANDOM_LCPU=y`, which executes the v8.5 `RNDR`
instruction at boot to seed the CSPRNG. If the outer emulated arm64 VM uses
an older CPU model like `cortex-a72` (Armv8.0-A), `-cpu host` in the nested
KVM guest inherits that CPU, lacks FEAT_RNG, and the unikernel traps on
`RNDR` before it can listen. Either:

1. Use `-cpu max` on the **outer** emulated arm64 VM so `-cpu host` in the
   nested KVM guest sees FEAT_RNG; or
2. Disable `CONFIG_LIBUKRANDOM_LCPU=y` in
   `apps/netperf/netperf.arm64.vsock.defconfig` and pass
   `random.seed=[…]` on the unikernel cmdline instead.

## Vsock notes

### Architecture

The vsock-enabled kernel (`unikraft-vsock/unikraft`) installs a transparent
**shim** in `lib/posix-socket/socket.c`. When the application calls
`socket(AF_INET, SOCK_STREAM, ...)` the shim:

1. Creates an AF_INET lwIP socket as a "stub" (kept for syscalls that vsock
   doesn't implement).
2. Creates a backing AF_VSOCK socket and swaps it in as the live socket.
3. Translates `bind(sockaddr_in)` → `bind(sockaddr_vm)` on the way in.
4. Translates `getsockname(sockaddr_vm)` → `sockaddr_in` on the way out so
   apps that introspect the bound port (e.g. netperf reporting the data port
   back to the peer) get a meaningful `sin_port`.

The netperf application sources are not modified. The whole transport switch
is invisible to the app — the same binary works against TCP if rebuilt with
the TCP defconfig, and against vsock with the vsock defconfig.

### Why arm64 only (today)

The Unikraft `virtio-pci` driver only implements the **legacy** virtio
spec — `drivers/virtio/pci/virtio_pci.c` rejects PCI device ids outside
`0x1000-0x103f`. `virtio-vsock` (id `0x1053`) is a modern-only device.
On the arm64 `virt` machine the vsock device rides a `virtio-mmio` bus
instead, and virtio-mmio handles modern devices fine. Implementing modern
virtio-pci in Unikraft would lift this restriction.

### vhost-vsock has no "off"

QEMU only ships one vsock backend (`vhost-vsock-pci` / `vhost-vsock-device`),
which always uses the host's `vhost_vsock` driver. Any vsock benchmark on
this stack is implicitly *vhost-accelerated*; there is no userspace
virtio-vsock to compare against.

## netperf command reference

`netperf` is the client, `netserver` is the server, and the unikernel is the
server. All `netperf` examples below run on the host.

Each `netperf` run consists of two connections:

1. **Control connection** to the configured port (`-p`, default 12865).
   Client and server negotiate the test type and parameters here.
2. **Data connection** on a port the server reports back over the control
   channel. This is ephemeral by default; pin it with `-P ,<port>` whenever
   port forwarding sits between client and server (Modes 1 and 4).

Anything before `--` is a global `netperf` flag. Anything after `--` is a
test-specific flag (each test type has its own parser).

### Test types (OMNI suite)

| Test         | Data direction                          | What it reports                                            | Key test flag       |
| ------------ | --------------------------------------- | ---------------------------------------------------------- | ------------------- |
| `TCP_STREAM` | client → server                         | Send-side throughput                                       | `-m <send_size>`    |
| `TCP_MAERTS` | server → client (`STREAM` reversed)     | Server-side send throughput                                | `-m <send_size>`    |
| `TCP_RR`     | bidirectional, single connection         | Completed request/response pairs per second                | `-r <req,resp>`     |
| `TCP_CRR`    | bidirectional, new connection per pair   | Transactions/sec including connect cost                    | `-r <req,resp>`     |
| `UDP_STREAM` | client → server                         | Send rate **and** receive rate (drops show up as the gap)  | `-m <datagram_size>` |
| `UDP_RR`     | bidirectional                           | Transactions / second                                      | `-r <req,resp>`     |

For RR tests the mean round-trip ≈ `1 / Trans. Rate` — e.g. 7179 trans/sec
≈ 139 µs RTT.

### Global flags (before `--`)

| Flag             | Meaning |
| ---------------- | ------- |
| `-H <host>`      | Target host (control connection). |
| `-p <port>`      | Control port. Default `12865`. |
| `-t <test>`      | Test name from the table above. Default `TCP_STREAM`. |
| `-l <secs>`      | Test length. Positive = seconds. Negative = bytes (STREAM) or transactions (RR). |
| `-4` / `-6`      | Force IPv4 / IPv6. |
| `-f <unit>`      | Output unit. Lowercase = bits/s (`g`/`m`/`k` = Gbit/Mbit/Kbit), uppercase = bytes/s (`G`/`M`/`K` = GB/MB/KB). |
| `-c` / `-C`      | Report local / remote CPU utilization. Always `-1.00` here — `netcpu_none.c` is linked. |
| `-D <secs>`      | Demo mode: emit an interim measurement every `<secs>` seconds. |
| `-P 0`           | Suppress banner / repeated header lines. |
| `-v <0..2>`      | Verbosity. `2` includes test parameters. |
| `-i <max,min>`   | Repeat until confidence interval converges (max / min retries). |

### Test-specific flags (after `--`)

| Flag                 | Tests       | Meaning |
| -------------------- | ----------- | ------- |
| `-m <bytes>`         | STREAM      | Bytes per `send()` call (TCP) or per datagram (UDP). |
| `-M <bytes>`         | STREAM      | Bytes per `recv()` call on the receiver. |
| `-r <req[,resp]>`    | RR / CRR    | Request / response size. `-r 1` = 1 byte each (lowest-latency probe). `-r 1024,1024` = 1 KB each. |
| `-s <send[,recv]>`   | all         | Local `SO_SNDBUF` / `SO_RCVBUF` set before connect. |
| `-S <send[,recv]>`   | all         | Remote socket buffers, set via the control channel. |
| `-P <local,remote>`  | all         | Pin data ports. `-P ,<remote>` keeps local ephemeral, pins remote. **Mandatory in Modes 1 and 4.** |
| `-D`                 | RR          | Set `TCP_NODELAY` (disable Nagle's). Important for low-latency RR. |
| `-o <cols>`          | OMNI        | Custom output columns. `netperf -- -O ?` prints the column catalogue. |

### Server-side flags (kernel cmdline `netperf -- …`)

These are `netserver` flags parsed by the unikernel. Default in
`apps/netperf/glue.c` is `-D -f -4 -p 12865`.

| Flag        | Meaning |
| ----------- | ------- |
| `-D`        | Do not daemonize (run in the foreground). |
| `-f`        | Do not spawn a child / pthread on `accept()` — single-threaded accept loop. Required: this unikernel does not implement `fork()` or pthread spawn-on-accept. |
| `-4`        | IPv4 only. |
| `-p <port>` | Listen on `<port>`. Default `12865`. |

### Reading the output

`TCP_STREAM` (Mbps):

```
Recv   Send    Send
Socket Socket  Message  Elapsed
Size   Size    Size     Time     Throughput
bytes  bytes   bytes    secs.    10^6bits/sec

131072 16384   1024     10.00     3357.41
```

- **Recv / Send Socket Size** — remote / local socket buffer sizes (`SO_RCVBUF` / `SO_SNDBUF`).
- **Message Size** — value of `-m`.
- **Throughput** — in the unit selected by `-f` (here Mbps).

`TCP_RR` (trans/sec):

```
Local /Remote
Socket Size   Request  Resp.   Elapsed  Trans.
Send   Recv   Size     Size    Time     Rate
bytes  Bytes  bytes    bytes   secs.    per sec

16384  131072 1024     1024    10.00    7179.42
```

- **Trans. Rate** — completed request/response pairs per second.
- Mean RTT ≈ `1 / Rate` (here ~139 µs).

### Recipe cheat-sheet

Replace `<addr>` with the guest IP (Modes 2 and 3) or `127.0.0.1` (Modes 1
and 4), `<ctrl>` with the control port (12865 / 20003 / 22865), and `<data>`
with the data port (only needed in Modes 1 and 4 — omit `-P ,<data>` in
Modes 2 and 3):

```bash
# Bulk TCP throughput, 1 KB sends
netperf -H <addr> -p <ctrl> -t TCP_STREAM -l 10 -- -m 1024 [-P ,<data>]

# Bulk TCP throughput, 64 KB sends (closer to socket buffer)
netperf -H <addr> -p <ctrl> -t TCP_STREAM -l 10 -- -m 65536 [-P ,<data>]

# Latency probe (1-byte ping-pong, Nagle off)
netperf -H <addr> -p <ctrl> -t TCP_RR -l 10 -- -r 1,1 -D [-P ,<data>]

# Symmetric 1 KB request/response throughput
netperf -H <addr> -p <ctrl> -t TCP_RR -l 10 -- -r 1024,1024 [-P ,<data>]

# Fixed-count instead of fixed-duration (1000 RR transactions)
netperf -H <addr> -p <ctrl> -t TCP_RR -l -1000 -- -r 1,1 [-P ,<data>]

# UDP bulk
netperf -H <addr> -p <ctrl> -t UDP_STREAM -l 10 -- -m 1400 [-P ,<data>]
```

## Repository layout

Files belonging to *this* project; cloned upstream trees are gitignored and
fetched by `setup.sh`. The vsock-enabled Unikraft tree is vendored.

```
netperf_unikraft/
├── README.md                           <-- you are here
├── setup.sh                            <-- clones unikraft + libs, applies patches
├── .gitignore                          <-- excludes cloned trees and build artifacts
├── patches/                            <-- patches applied to cloned dependencies
│   ├── 0001-unikraft-posix-tty-init-priority.patch
│   └── 0002-lwip-rcvbuf-default.patch
├── apps/netperf/                       <-- the app package
│   ├── Makefile, Makefile.uk
│   ├── Config.uk                       <-- Kconfig (deps, OMNI toggle)
│   ├── netperf.defconfig               <-- x86_64 TCP build config
│   ├── netperf.arm64.defconfig         <-- arm64 TCP build config
│   ├── netperf.arm64.vsock.defconfig   <-- arm64 vsock build config
│   ├── build_arm64.sh                  <-- arm64 TCP cross-compile wrapper
│   ├── build_vsock.sh                  <-- arm64 vsock cross-compile wrapper
│   ├── netperf_vsock.sh                <-- vsock QEMU runner (arm64)
│   ├── glue.c                          <-- owns main(), calls netserver_main()
│   ├── exportsyms.uk
│   ├── include/
│   │   ├── config.h                    <-- autoconf shim for netperf
│   │   └── netperf_version.h
│   └── patches/                        <-- patches applied to the netperf 2.7.0 tarball
│       ├── 0001-unikraft-stubs.patch
│       ├── 0002-sndbuf-fallback.patch
│       └── 0003-allocate-buffer-ring-sanitize.patch
├── unikraft-vsock/                     <-- vendored vsock-enabled Unikraft tree
│   ├── unikraft/                       <-- NatsuCamellia/unikraft @ vsock branch (+ two shim fixes)
│   └── libs/{lwip,musl,iperf3}/
└── (after running setup.sh — gitignored)
    ├── unikraft/                       <-- github.com/unikraft/unikraft
    └── libs/{lwip,musl,compiler-rt}/   <-- github.com/unikraft/lib-*
```

## Required build features

The non-obvious Kconfig entries shared by every defconfig:

| Config option                          | Why it's required                                                                                          |
| -------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `CONFIG_APPNETPERF_USE_OMNI=y`         | OMNI test engine (TCP_STREAM, TCP_RR, UDP_*). Without it only legacy BSD tests build.                       |
| `CONFIG_LIBVIRTIO_NET=y`               | virtio-net driver (used by lwIP even in vsock mode for the stub stack).                                     |
| `CONFIG_LIBLWIP=y` + `LWIP_*`          | TCP/IP stack, IPv4, UDP, DHCP, sockets, threads, uknetdev glue.                                             |
| `CONFIG_LIBUKNETDEV_EINFO_LIBPARAM=y`  | Required for `netdev.ip=<cidr>:<gw>` cmdline param. Without it cmdline IP is silently ignored — fatal on tap0 where there is no DHCP server. |
| `CONFIG_LIBUKRANDOM_LCPU=y`            | Auto-seed the CSPRNG. x86_64 uses RDRAND/RDSEED; arm64 uses Armv8.5-A FEAT_RNG (auto-bumps `-march` to `armv8.5-a+rng`). Requires `-cpu max` (TCG) or `-enable-kvm -cpu host`. |
| `CONFIG_LIBUKRANDOM_CMDLINE_SEED=y`    | Manual override fallback (`random.seed=[…]` on the cmdline wins if provided).                              |
| `CONFIG_LIBUKPRINT_KLVL_INFO=y`        | Default is ERR; INFO is needed to see boot lines.                                                            |
| `CONFIG_LIBPOSIX_POLL=y`               | netserver uses `select()` (provided by posix-poll).                                                          |
| `CONFIG_LIBUKMMAP=y`                   | netperf calls `mmap` indirectly through musl.                                                                |
| `CONFIG_LIBUKSCHEDCOOP=y`              | Cooperative scheduler. lwIP threading needs *a* scheduler.                                                   |

Vsock-only:

| Config option            | Purpose                                                                       |
| ------------------------ | ----------------------------------------------------------------------------- |
| `CONFIG_LIBUKVSOCKDEV=y` | vsock device abstraction (enables the transparent posix-socket shim).         |
| `CONFIG_LIBVIRTIO_VSOCK=y` | virtio-vsock driver (rides the virtio-mmio transport on `-M virt`).         |
| `CONFIG_LIBVIRTIO_MMIO=y` | virtio-mmio transport (vsock cannot use virtio-pci — see [Vsock notes](#vsock-notes)). |

Arch / platform differences between defconfigs:

| Target  | Options                                                                                                                            |
| ------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| x86_64  | `CONFIG_ARCH_X86_64=y`, `CONFIG_PLAT_KVM=y`, `CONFIG_KVM_VMM_QEMU=y` (multiboot proto auto-selected, NS16550 console)               |
| arm64   | `CONFIG_ARCH_ARM_64=y`, `CONFIG_PLAT_KVM=y`, `CONFIG_KVM_VMM_QEMU=y`, `CONFIG_KVM_BOOT_PROTO_LXBOOT=y`, `CONFIG_MCPU_ARM64_GENERIC=y` (PL011 console, GICv2, PL031 RTC, PSCI all auto-selected). |

## Known limitations

- **vsock benchmarks on an x86 host are TCG-emulated** (arm64 guest under
  QEMU TCG). CPU emulation overhead dominates. For meaningful vsock-vs-TCP
  numbers, run on real arm64 with KVM. The pipeline is identical.
- **No x86_64 vsock build.** Blocked on Unikraft's legacy-only virtio-pci
  driver. See [Vsock notes](#vsock-notes).
- **No vhost-vsock "off"** in QEMU. The vsock data point is single-valued;
  there is no userspace backend to compare against.
- **`setitimer` / `SIGALRM` is stubbed.** Server-side test-length timers do
  not fire. End-of-test still works because the client closes its data
  socket; netserver detects EOF and returns OMNI results.
- **Cooperative scheduler only.** `LIBUKSCHEDCOOP` is the only scheduler
  tested.
- **No CPU-utilization reporting.** `netcpu_none.c` is linked — netperf
  prints `-1.00` for cpu util. Throughput / latency numbers are valid.
- **Single connection at a time.** `spawn_on_accept = 0`; second concurrent
  client blocks on accept.
- **netperf client is not ported.** Only the server. The client runs on the
  host (`sudo apt-get install netperf`).

## Porting story

Seven bugs / gaps were fixed to make this land. Five are required to make
the TCP build boot and accept data; two more are required by netperf
specifically on top of the iperf3 vsock shim.

### Bug 1 — `init_posix_tty` and `init_tty_cons` never ran

**Symptom.** Unikernel boots silently. The first `fprintf` returns `EBADF`
because stdin/stdout/stderr were never opened.

**Root cause.** The macro chain
`UK_PRIO_AFTER(UK_PRIO_AFTER(UK_FS_PRIO_FSAVAIL))` doesn't fully expand to a
numeric token *before* being stringified in
`__section(".uk_inittab" #base #prio)`. The resulting section name is never
merged into `.uk_inittab`.

**Fix.** Replace `UK_FS_PRIO_FSAVAIL` with a literal numeric priority.

File changed: `unikraft/lib/posix-tty/tty.c` →
`uk_rootfs_initcall_prio(init_posix_tty, 0x0, 2)`.

### Bug 2 — lwIP `RECV_BUFSIZE_DEFAULT = INT_MAX`

**Symptom.** TCP_STREAM crashes inside `virtqueue_ring_interrupt`.

**Root cause.** `getsockopt(SO_RCVBUF)` returns `INT_MAX`. Netperf reads it
back as the receive buffer size and the OMNI default-fill loop writes 2 GiB
of `"netperf"` past the end of a 16 KiB allocation, corrupting virtio queue
descriptors on the heap.

**Fix.** Override `RECV_BUFSIZE_DEFAULT` to `TCP_WND` (262142).

File changed: `libs/lwip/include/lwipopts.h`.

### Bug 3 — lwIP doesn't implement `getsockopt(SO_SNDBUF)`

**Symptom.** Netperf stored `-1` in `effective_sizep` after `ENOPROTOOPT`;
downstream buffer-ring arithmetic wrapped to ~2 GiB.

**Fix.** Patch `get_sock_buffer` in `src/netlib.c` to return 16 384 on
`getsockopt` failure.

File created: `apps/netperf/patches/0002-sndbuf-fallback.patch`.

### Bug 4 — `allocate_buffer_ring` trusts caller inputs

**Fix (defense-in-depth).** Clamp `width`, `alignment`, `offset`,
`buffer_size` to sane ranges.

File created: `apps/netperf/patches/0003-allocate-buffer-ring-sanitize.patch`.

### Bug 5 — netserver wants to `fork()` on accept

**Fix.** Patch `init_netserver_globals()` to force
`spawn_on_accept = 0, want_daemonize = 0, not_inetd = 1`; rename `main` →
`netserver_main` so `glue.c` can wrap it.

File created: `apps/netperf/patches/0001-unikraft-stubs.patch`.

### Vsock-specific 1 — Vsock socket creation fails on `IPPROTO_TCP`

**Symptom.** Netperf's OMNI server calls
`socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)`. The vsock shim forwards
`protocol=6` to `posix_socket_create(AF_VSOCK, ...)`, and the virtio-vsock
driver rejects any protocol other than 0 (`EPROTONOSUPPORT`). The shim's
vsock socket creation silently fails, so the shim falls back to lwIP and the
data socket binds to lwIP TCP — invisible to the host vsock bridge.

**Fix.** In `unikraft-vsock/unikraft/lib/posix-socket/socket.c`, force
`protocol=0` when creating the backing vsock socket. `AF_VSOCK` has its own
protocol space and the AF_INET app's `IPPROTO_TCP` is not meaningful inside
it.

### Vsock-specific 2 — `getsockname` returns `sockaddr_vm`

**Symptom.** Server reports `data_port = 0` to the client. Client connects
to port 0; the data connection times out.

**Root cause.** Netperf does `getsockname()` after `listen()` and casts the
result to `sockaddr_in` to read the bound port. The shim did not intercept
`getsockname`, so the call returned a raw `sockaddr_vm`. Cast to
`sockaddr_in`, the bytes read as `sin_port` were actually `svm_reserved1`,
which is always zero.

**Fix.** In the shim, intercept `getsockname` for shim-backed sockets and
translate the `sockaddr_vm` into a synthetic
`sockaddr_in { sin_family=AF_INET, sin_port=htons(svm_port), sin_addr=0 }`.

## How patches are applied

Two patch sets, applied at different stages:

**Dependency patches** (in `patches/`) are applied by `setup.sh` to the
cloned upstream trees right after checkout. They are tracked here because
upstream Unikraft / lwIP don't carry the fixes yet.

**Vendored vsock-kernel patches** are committed directly into
`unikraft-vsock/` (it is a vendored tree, not a clone — `setup.sh` doesn't
touch it). The two patches under `patches/` apply cleanly there too if you
ever need to re-derive them.

**netperf source patches** (in `apps/netperf/patches/`) are applied
automatically by Unikraft's build system, which fetches the netperf 2.7.0
tarball, extracts it under `apps/netperf/build*/appnetperf/origin/`, and
applies the patches in numeric order.

```make
$(eval $(call fetch,appnetperf,$(APPNETPERF_URL)))
$(eval $(call patch,appnetperf,$(APPNETPERF_PATCHDIR),$(APPNETPERF_ZIPNAME)))
```

If you edit a netperf patch, delete
`apps/netperf/build*/appnetperf/{origin,.origin,.patched}` and rebuild.

## Acknowledgements

The vsock kernel is `NatsuCamellia/unikraft` branch `vsock`, originally
developed for the [iperf3 vsock case
study](https://github.com/unikraft/app-iperf3). The two extra shim fixes
above were needed because netperf exercises more of the AF_INET socket
surface than iperf3 does.
