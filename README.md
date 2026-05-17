# netperf on Unikraft

A port of **netserver** (the listening side of the netperf benchmark suite) to
the [Unikraft](https://unikraft.org) unikernel framework. The host-side
`netperf` client drives tests against the unikernel over a virtio-net link.

| | |
| --- | --- |
| Source release | netperf **2.7.0** (HewlettPackard/netperf) |
| Unikraft tree   | based on 0.21.0 (Ijiraq), patched (see below) |
| Tests verified  | TCP_STREAM, TCP_RR, UDP_STREAM, UDP_RR |
| Image size      | ~1.5 MB stripped |
| Boot to listen  | ~0.13 s (TCG), < 0.05 s (KVM) |

## Status

**Working end-to-end.** Both QEMU user-mode and tap0 + vhost-net are exercised.

Verified results (Intel WSL2, TCG, single vcpu):

| Test                 | User-mode (`-netdev user`) | tap0 + vhost-net |
| -------------------- | -------------------------: | ---------------: |
| TCP_STREAM 1 KB msg  |                    443 Mbps |     **4156 Mbps** |
| TCP_STREAM 8 KB msg  |                   1439 Mbps |     **3357 Mbps** |
| TCP_STREAM 64 KB msg |                    548 Mbps |     **3450 Mbps** |
| TCP_RR 1 KB req/resp |              2630 trans/sec | **7179 trans/sec** |

Tap+vhost gives roughly 7x the user-mode throughput. Use tap for any actual
benchmarking; use user-mode for quick smoke tests where no host setup is
acceptable.

## What this project contributes

A turn-key netperf server unikernel plus the upstream fixes that were needed
to make it land. Concretely:

1. **App package** (`apps/netperf/`) — Makefile.uk, Config.uk, defconfig,
   glue.c that wraps `netserver_main`, and three source patches.
2. **lwIP fix** (`libs/lwip/include/lwipopts.h`) — override of
   `RECV_BUFSIZE_DEFAULT` so `getsockopt(SO_RCVBUF)` no longer returns
   `INT_MAX`. Without this the unikernel crashes on the first data transfer.
3. **Unikraft fix** (`unikraft/lib/posix-tty/{tty,serial}.c`) — a Kconfig
   priority-macro stringification bug that prevented `init_posix_tty` and
   `init_tty_cons` from ever running. Without this the unikernel is silent
   on the console and may assert later when stdio is touched.

The five bugs and the two UX wins are described in detail in
[Porting story](#porting-story).

## Repository layout

Only the files that belong to *this project* are tracked. The Unikraft kernel
and lib repos are cloned and patched on demand by `setup.sh`.

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
│   ├── netperf.defconfig               <-- canonical build config
│   ├── glue.c                          <-- owns main(), calls netserver_main()
│   ├── exportsyms.uk
│   ├── include/
│   │   ├── config.h                    <-- autoconf shim for netperf
│   │   └── netperf_version.h
│   └── patches/                        <-- patches applied to the netperf 2.7.0 tarball
│       ├── 0001-unikraft-stubs.patch
│       ├── 0002-sndbuf-fallback.patch
│       └── 0003-allocate-buffer-ring-sanitize.patch
└── (after running setup.sh — gitignored)
    ├── unikraft/                       <-- github.com/unikraft/unikraft
    └── libs/{lwip,musl,compiler-rt}/   <-- github.com/unikraft/lib-*
```

The pinned upstream commits and the patches applied to them are in
`setup.sh`. The netperf source itself (`netperf-2.7.0.tar.gz`) is fetched and
patched automatically by Unikraft's build system using
`apps/netperf/patches/*`.

## Quick start (tap0 + vhost-net, recommended for benchmarking)

### 0. Build prerequisites

```bash
sudo apt-get install -y git patch wget build-essential bison flex \
                        libncurses-dev python3 qemu-system-x86 unzip
```

### 1. Clone dependencies and apply patches

```bash
git clone <this-repo> netperf_unikraft
cd netperf_unikraft
./setup.sh           # clones unikraft + libs at pinned SHAs, applies ./patches/*
```

`setup.sh` is idempotent — safe to re-run; existing clones are kept and only
re-checkout'd, and patches that are already applied are skipped.

### 2. Host setup (one-time, requires sudo)

```bash
# Create a persistent tap owned by your user so QEMU opens it without sudo.
sudo ip tuntap add dev tap0 mode tap user "$USER"
sudo ip addr add 172.31.0.1/24 dev tap0
sudo ip link set dev tap0 up

# vhost-net accelerator: load module and grant access to the char device.
sudo modprobe vhost_net
sudo chmod a+rw /dev/vhost-net      # or add your user to the kvm group

# Install the netperf client.
sudo apt-get install -y netperf
```

### 3. Build

```bash
cd apps/netperf
cp netperf.defconfig .config
make olddefconfig
make -j$(nproc)
# image: build/netperf_qemu-x86_64
```

### 4. Run the unikernel (server)

```bash
qemu-system-x86_64 -display none -no-reboot -nographic \
  -kernel build/netperf_qemu-x86_64 \
  -m 256 -cpu max \
  -netdev tap,id=hn0,ifname=tap0,script=no,downscript=no,vhost=on,vhostforce=on \
  -device virtio-net-pci,netdev=hn0 \
  -append "netperf netdev.ip=172.31.0.2/24:172.31.0.1 -- -D -f -4 -p 12865"
```

### 5. Drive tests from the host

```bash
netperf -H 172.31.0.2 -p 12865 -t TCP_STREAM -l 10 -- -m 1024
netperf -H 172.31.0.2 -p 12865 -t TCP_RR     -l 10 -- -r 1024
netperf -H 172.31.0.2 -p 12865 -t UDP_STREAM -l 10 -- -m 1400
netperf -H 172.31.0.2 -p 12865 -t UDP_RR     -l 10
```

## Alternative: QEMU user-mode (no host setup, slower)

For quick smoke tests when you don't want to touch host networking:

```bash
qemu-system-x86_64 -display none -no-reboot -nographic \
  -kernel build/netperf_qemu-x86_64 \
  -m 256 -cpu max \
  -netdev user,id=hn0,hostfwd=tcp::20003-:12865,hostfwd=tcp::12866-:12866 \
  -device virtio-net-pci,netdev=hn0 \
  -append "netperf -- -D -f -4 -p 12865"

# Note the -P ,12866 pinning so the OMNI data port matches the second hostfwd.
netperf -H 127.0.0.1 -p 20003 -t TCP_STREAM -l 10 -- -m 1024 -P ,12866
```

## Required build features

`netperf.defconfig` is the source of truth. The non-obvious entries:

| Config option                          | Why it's required                                                                                          |
| -------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `CONFIG_APPNETPERF_USE_OMNI=y`         | Enables the OMNI test engine (TCP_STREAM, TCP_RR, UDP_*, etc.). Without it only legacy BSD tests build.    |
| `CONFIG_LIBVIRTIO_NET=y`               | virtio-net driver.                                                                                         |
| `CONFIG_LIBLWIP=y` + `LWIP_*`          | TCP/IP stack, IPv4, UDP, DHCP, sockets, threads, uknetdev glue.                                            |
| `CONFIG_LIBUKNETDEV_EINFO_LIBPARAM=y`  | Required for `netdev.ip=<cidr>:<gw>` cmdline param. Without it cmdline IP is silently ignored — fatal on tap0 where there is no DHCP server. |
| `CONFIG_LIBUKRANDOM_LCPU=y`            | Auto-seed the CSPRNG via RDRAND/RDSEED. Lets you run without `random.seed=[...]` on the cmdline. Requires `-cpu max` (or `-enable-kvm -cpu host`). |
| `CONFIG_LIBUKRANDOM_CMDLINE_SEED=y`    | Kept as a manual override; useful for reproducible runs.                                                   |
| `CONFIG_LIBUKPRINT_KLVL_INFO=y`        | Default log level is ERR. Without INFO you can't see the lwIP / virtio init lines that confirm boot.       |
| `CONFIG_LIBPOSIX_POLL=y`               | `accept_connections()` uses `select()` which is provided by posix-poll.                                    |
| `CONFIG_LIBUKMMAP=y`                   | netperf calls `mmap` indirectly through musl.                                                              |
| `CONFIG_LIBUKSCHEDCOOP=y`              | Cooperative scheduler. lwIP threading needs *a* scheduler.                                                 |

QEMU flags that matter:

| Flag                                                   | Reason                                                                       |
| ------------------------------------------------------ | ---------------------------------------------------------------------------- |
| `-cpu max` (TCG) or `-enable-kvm -cpu host`            | Exposes RDRAND so `libukrandom_lcpu` can seed the CSPRNG without cmdline.    |
| `-netdev tap,...,vhost=on,vhostforce=on`               | vhost-net offload; ~7x throughput vs. plain tap.                             |
| `-append "netperf netdev.ip=<cidr>:<gw> -- <args>"`    | Format is one colon-separated string, **not** `netdev.ipv4_addr=` etc.       |

## Porting story

Five bugs blocked the port. Three UX issues showed up after the port was
green. Here's each one and the fix.

### Bug 1 — `init_posix_tty` and `init_tty_cons` never ran

**Symptom.** The unikernel boots silently. The first `fprintf` from the app
returns `EBADF` because stdin/stdout/stderr were never opened. Later
assertions fire on file-descriptor lookups.

**Root cause.** The macro chain
`UK_PRIO_AFTER(UK_PRIO_AFTER(UK_FS_PRIO_FSAVAIL))` doesn't fully expand to a
numeric token *before* being stringified in
`__section(".uk_inittab" #base #prio)`. The resulting section name comes out
as `.uk_inittab4__UK_PRIO_AFTER___UK_PRIO_AFTER_UK_FS_PRIO_FSAVAIL` — which
the linker never merges into the `.uk_inittab` block, so the init function
is never called.

**Fix.** Replace the macro chain with literal numeric priorities.

Files changed:
- `unikraft/lib/posix-tty/tty.c` — `uk_rootfs_initcall_prio(init_posix_tty, 0x0, 4)`
- `unikraft/lib/posix-tty/serial.c` — `uk_rootfs_initcall_prio(init_tty_cons, 0x0, 3)` and `(…, 2)`

Both files leave an explanatory comment above each call so the workaround is
discoverable.

### Bug 2 — lwIP `RECV_BUFSIZE_DEFAULT = INT_MAX`

**Symptom.** TCP_STREAM crashes inside `virtqueue_ring_interrupt` with
`rdi = "netperf\0\0"`. The crash is far away from the actual fault —
kernel-land, in an unrelated IRQ.

**Root cause.** `getsockopt(SO_RCVBUF)` returns `INT_MAX` (2147483647)
because lwIP's `opt.h:2031` defines `RECV_BUFSIZE_DEFAULT` as `INT_MAX`.
Netperf reads this value back, uses it as the *receive buffer size*, then
the OMNI test's default-fill loop writes 2 GiB of the string `"netperf"` past
the end of a 16 KiB allocation. The overflow corrupts virtio queue
descriptors on the heap. The kernel survives until the next IRQ, then dies.

**Fix.** Override `RECV_BUFSIZE_DEFAULT` to `TCP_WND` (262142) inside the
`CONFIG_LWIP_RCVBUF` block.

File changed:
- `libs/lwip/include/lwipopts.h` — lines 218–224

```c
#if CONFIG_LWIP_RCVBUF
#define LWIP_SO_RCVBUF 1
/* Override lwIP's default of INT_MAX; netperf reads this value back via
 * getsockopt(SO_RCVBUF) and uses it to size receive buffers, so a huge
 * default causes catastrophic over-allocation. */
#define RECV_BUFSIZE_DEFAULT (TCP_WND)
#endif
```

### Bug 3 — lwIP doesn't implement `getsockopt(SO_SNDBUF)`

**Symptom.** `getsockopt(sd, SOL_SOCKET, SO_SNDBUF, ...)` returns -1 with
`errno = 92 (ENOPROTOOPT)`. Netperf stored `-1` in `effective_sizep`;
downstream buffer-ring arithmetic turned that into a negative `malloc_size`
that wrapped to ~2 GiB.

**Fix.** Patch `get_sock_buffer` in `src/netlib.c`: on `getsockopt` failure
return a sane default of 16 384 instead of -1, and suppress the
per-connection error message unless the user is actively debugging (the
fallback is informational only — actual lwIP send-path buffering is
unaffected).

File created: `apps/netperf/patches/0002-sndbuf-fallback.patch`

### Bug 4 — `allocate_buffer_ring` trusts caller inputs

**Symptom.** Same overflow as Bug 2, but as a defence-in-depth measure.

**Root cause.** The alignment arithmetic in
`netlib.c:allocate_buffer_ring` —
`buffer_ptr = (buffer_base + alignment - 1) & ~(alignment - 1)` —
silently breaks for non-power-of-two alignments. The default-fill loop also
trusts `buffer_size`.

**Fix.** Clamp all four caller-supplied parameters to sane ranges before
using them:
- `width` ∈ [1, 1024], default 2
- `alignment` power-of-two ∈ [1, 4096], default 8
- `offset` ∈ [0, alignment), default 0
- `buffer_size` ∈ [1, 16 MiB], default 16 384

File created: `apps/netperf/patches/0003-allocate-buffer-ring-sanitize.patch`

### Bug 5 — netserver wants to `fork()` on accept

**Symptom.** First incoming connection causes a clone/fork stub warning and
the connection is never handled.

**Root cause.** Default netserver behaviour is to fork a child per
connection (`spawn_on_accept = 1`) or daemonize (`want_daemonize = 1`).
Unikraft has neither fork nor daemonization.

**Fix.** Patch `init_netserver_globals()` to force `spawn_on_accept = 0,
want_daemonize = 0, not_inetd = 1`, and rename `main` → `netserver_main` so
`glue.c` can wrap it and supply default argv if the user passes none.

File created: `apps/netperf/patches/0001-unikraft-stubs.patch`

### UX 1 — `errno 92` printed on every connection

After Bug 3 was patched, the unikernel survived but its console scrolled
`netperf: get_sock_buffer: getsockopt SO_SNDBUF: errno 92` on every accept.
Patch 0002 was tightened so the message only prints under `debug` (the
fallback path is internally consistent — the message was informational).

### UX 2 — Manual `random.seed=[…]` required at boot

The original `netperf.defconfig` only enabled `LIBUKRANDOM_CMDLINE_SEED`, so
every invocation needed
`-append "netperf random.seed=[0x… 0x… 0x… …] …"` with eight 32-bit words
of entropy. Annoying for scripting.

**Fix.** Added `CONFIG_LIBUKRANDOM_LCPU=y` so the CPU-side RDRAND/RDSEED
driver auto-seeds the CSPRNG. `LIBUKRANDOM_CMDLINE_SEED` is kept enabled as
a manual override (the cmdline seed wins if provided). Requires
`-cpu max` (TCG) or `-enable-kvm -cpu host`.

### UX 3 — `netdev.ipv4_addr=` was a phantom param

The earlier README claimed you could pass
`netdev.ipv4_addr=172.31.0.2 netdev.ipv4_gw_addr=172.31.0.1 …` on the
cmdline. Two problems:
1. `CONFIG_LIBUKNETDEV_EINFO_LIBPARAM` was off, so cmdline IP params were
   compiled out entirely. The guest silently fell back to DHCP, which has
   no server on tap0.
2. The actual param is a single colon-separated string:
   `netdev.ip=<cidr>[:<gw>[:<dns0>[:<dns1>[:<hostname>[:<domain>]]]]]`.

**Fix.** Enabled `CONFIG_LIBUKNETDEV_EINFO_LIBPARAM=y` in the defconfig and
updated docs to use the real `netdev.ip=` syntax.

## Files modified — full list

### Inside `apps/netperf/` (new code)

| File                                          | Purpose                                                                                  |
| --------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `Makefile.uk`                                 | Source list (netserver/netlib/netsh/nettest_bsd/nettest_omni/netcpu_none/dscp/net_uuid + glue.c), `-DHAVE_CONFIG_H`, `-DDO_IPV6=0`, `-fcommon`, warning suppressors. |
| `Config.uk`                                   | Kconfig: dependencies + `APPNETPERF_USE_OMNI` toggle.                                    |
| `netperf.defconfig`                           | Canonical build configuration (see [Required build features](#required-build-features)). |
| `glue.c`                                      | Owns `main()`. If argc==1 supplies default argv (`-D -f -4 -p 12865`); otherwise forwards to `netserver_main`. |
| `include/config.h`                            | Autoconf shim — feature macros netperf's source assumes when built with `HAVE_CONFIG_H`. |
| `include/netperf_version.h`                   | Version stamp.                                                                           |
| `exportsyms.uk`                               | (Empty / no exported symbols needed for an app.)                                         |
| `patches/0001-unikraft-stubs.patch`           | netserver no-fork / no-daemon / `main` → `netserver_main` rename.                        |
| `patches/0002-sndbuf-fallback.patch`          | `get_sock_buffer` returns 16384 on getsockopt failure; suppress per-conn errno message.  |
| `patches/0003-allocate-buffer-ring-sanitize.patch` | Clamp width/alignment/offset/buffer_size in `allocate_buffer_ring`.                 |

### Top-level `patches/` (applied to cloned dependencies by `setup.sh`)

| Patch                                                  | Target tree                | What it changes                                                                                  |
| ------------------------------------------------------ | -------------------------- | ------------------------------------------------------------------------------------------------ |
| `0001-unikraft-posix-tty-init-priority.patch`          | `unikraft/lib/posix-tty/`  | `tty.c` and `serial.c` use literal numeric init priorities (workaround for the section-name stringification bug). |
| `0002-lwip-rcvbuf-default.patch`                       | `libs/lwip/include/`       | `lwipopts.h` overrides `RECV_BUFSIZE_DEFAULT` to `TCP_WND` inside the `CONFIG_LWIP_RCVBUF` block. |

Both patches are tiny and well-commented in-line so the workaround stays
discoverable in the patched source.

## How patches are applied

There are two patch sets, applied at different stages:

**Dependency patches** (in `patches/`) are applied by `setup.sh` to the
cloned upstream trees right after checkout. They are tracked here because
the upstream Unikraft / lwIP repos don't yet carry the fixes.

**netperf source patches** (in `apps/netperf/patches/`) are applied
automatically by Unikraft's build system, which fetches the netperf 2.7.0
tarball, extracts it under `apps/netperf/build/appnetperf/origin/`, and
applies the patches in numeric order. The `Makefile.uk` hooks this in via
the standard Unikraft macros:

```make
$(eval $(call fetch,appnetperf,$(APPNETPERF_URL)))
$(eval $(call patch,appnetperf,$(APPNETPERF_PATCHDIR),$(APPNETPERF_ZIPNAME)))
```

If you edit a netperf patch, delete
`apps/netperf/build/appnetperf/{origin,.origin,.patched}` and rebuild.
If you edit a dependency patch, re-run `./setup.sh` (it detects already-applied
patches and skips them, so to re-apply after editing you need to revert the
target file in the cloned tree first).

## Known limitations / future work

- **`setitimer` / `SIGALRM` is stubbed.** Server-side test-length timers do
  not fire. End-of-test still works because the client closes its data
  socket; netserver detects EOF and returns OMNI results. Would only matter
  if a client misbehaves and never closes.
- **Cooperative scheduler.** `LIBUKSCHEDCOOP` is the only scheduler tested.
  Preemptive (`LIBUKSCHED`) has not been exercised.
- **No CPU-utilization reporting.** `netcpu_none.c` is linked — netperf will
  print `-1.00` for cpu util. There is no `/proc/stat` or `kstat` on a
  unikernel; throughput/latency numbers are valid.
- **Single connection at a time.** `spawn_on_accept = 0` means the server
  handles one client serially; a second concurrent client will block on
  accept. Fine for sequential benchmarks, not a general workload.
- **netperf client is not ported.** Only the server. The client runs on the
  host (`sudo apt-get install netperf`).

## Acknowledgements

Modelled after the [`app-iperf3`](https://github.com/unikraft/app-iperf3)
case study. The TTY priority-macro workaround was first observed when
adding `LIBPOSIX_PROCESS` and tracking down why stdio failed to open.
