#!/usr/bin/env bash
# Build the netperf unikernel WITH vsock support (arm64).
#
# vsock requires the modern virtio transport: virtio-vsock is a modern-only
# virtio device and Unikraft's virtio-pci driver is legacy-only, so vsock
# cannot run on the x86 `pc` PCI bus. Like iperf3-unikraft, we therefore build
# for arm64 and run on `qemu-system-aarch64 -M virt`, where the vsock device
# rides a virtio-mmio bus. On an x86 host this is cross-compiled and runs under
# QEMU TCG; on real arm64 hardware it is KVM-native.
#
# The kernel is the vsock-enabled tree vendored at ../../unikraft-vsock/unikraft
# (the exact kernel iperf3-unikraft uses). Its posix-socket layer transparently
# rewrites AF_INET SOCK_STREAM sockets to AF_VSOCK, so the netperf application
# sources are unchanged.
#
# Output lands in apps/netperf/build-vsock/ so it never collides with the
# x86 TCP build in apps/netperf/build/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/apps/netperf"

UK_VSOCK="$ROOT/unikraft-vsock/unikraft"
# musl + lwip come from the vsock tree (tested against that kernel);
# compiler-rt is kernel-version agnostic and reused from the TCP checkout.
LIBS="$ROOT/unikraft-vsock/libs/musl:$ROOT/libs/compiler-rt:$ROOT/unikraft-vsock/libs/lwip"

CROSS=aarch64-linux-gnu-
BUILD_DIR="$APP/build-vsock"
CONFIG="$BUILD_DIR/.config"

apply_patch() {
	local target="$1" patch="$2"
	if patch -d "$target" -p1 --dry-run --reverse --silent < "$patch" >/dev/null 2>&1; then
		echo "[skip patch] $(basename "$patch") already applied to $target"
		return 0
	fi
	echo "[patch]      $(basename "$patch") -> $target"
	patch -d "$target" -p1 --silent < "$patch"
}

# Same two upstream fixes the TCP build needs (see setup.sh), applied to the
# vsock kernel + its lwip checkout.
apply_patch "$UK_VSOCK"                      "$ROOT/patches/0001-unikraft-posix-tty-init-priority.patch"
apply_patch "$ROOT/unikraft-vsock/libs/lwip" "$ROOT/patches/0002-lwip-rcvbuf-default.patch"

mkdir -p "$BUILD_DIR"
cp "$APP/netperf.arm64.vsock.defconfig" "$CONFIG"

# CROSS_COMPILE must be passed to BOTH olddefconfig and the build.
make -C "$UK_VSOCK" A="$APP" L="$LIBS" O="$BUILD_DIR" C="$CONFIG" \
	CROSS_COMPILE="$CROSS" olddefconfig
make -C "$UK_VSOCK" A="$APP" L="$LIBS" O="$BUILD_DIR" C="$CONFIG" \
	CROSS_COMPILE="$CROSS" -j"$(nproc)"

echo
echo "vsock netperf image: $BUILD_DIR/netperf_qemu-arm64"
echo "run it with: ./netperf_vsock.sh"
