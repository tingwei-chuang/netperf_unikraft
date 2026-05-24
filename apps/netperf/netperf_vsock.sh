#!/usr/bin/env bash
# Run the vsock-enabled netperf server (arm64).
#
# vsock rides a virtio-mmio bus (virtio-vsock is modern-only; Unikraft's
# virtio-pci is legacy-only). virtio-net stays on PCI for the lwIP stub stack.
# On an x86 host this runs under QEMU TCG; on real arm64 it would be KVM.
set -x

KERNEL=./build-vsock/netperf_qemu-arm64

qemu-system-aarch64 \
  -M virt -cpu max \
  -display none -no-reboot -nographic \
  -kernel "${KERNEL}" \
  -m 256 \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0 \
  -device vhost-vsock-device,bus=virtio-mmio-bus.0,guest-cid=3 \
  -append "netperf -- -D -f -4 -p 12865"
