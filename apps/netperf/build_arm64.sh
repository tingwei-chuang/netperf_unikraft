#!/usr/bin/env bash
# Cross-compile the netperf unikernel for arm64 (TCP, no vsock).
#
# Uses the upstream Unikraft kernel cloned by setup.sh and the existing
# arm64 defconfig. Image lands at apps/netperf/build-arm64/netperf_qemu-arm64
# so it does not collide with the x86_64 build (apps/netperf/build/) or the
# arm64 vsock build (apps/netperf/build-vsock/). For the vsock variant see
# build_vsock.sh.
#
# Run `./setup.sh` first to clone Unikraft + libs and apply patches.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/apps/netperf"

UK_ROOT="$ROOT/unikraft"
LIBS="$ROOT/libs/musl:$ROOT/libs/compiler-rt:$ROOT/libs/lwip"
CROSS=aarch64-linux-gnu-

BUILD_DIR="$APP/build-arm64"
CONFIG="$BUILD_DIR/.config"

if [[ ! -d "$UK_ROOT/.git" ]]; then
	echo "Error: $UK_ROOT not found. Run ./setup.sh first." >&2
	exit 1
fi

mkdir -p "$BUILD_DIR"
cp "$APP/netperf.arm64.defconfig" "$CONFIG"

# CROSS_COMPILE must be passed to BOTH olddefconfig and the build.
make -C "$UK_ROOT" A="$APP" L="$LIBS" O="$BUILD_DIR" C="$CONFIG" \
	CROSS_COMPILE="$CROSS" olddefconfig
make -C "$UK_ROOT" A="$APP" L="$LIBS" O="$BUILD_DIR" C="$CONFIG" \
	CROSS_COMPILE="$CROSS" -j"$(nproc)"

echo
echo "arm64 netperf image: $BUILD_DIR/netperf_qemu-arm64"
