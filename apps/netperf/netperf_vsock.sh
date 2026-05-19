#!/usr/bin/env bash
set -x

KERNEL=./build/netperf_qemu-x86_64

qemu-system-x86_64 \
  -display none -no-reboot -nographic \
  -kernel "${KERNEL}" \
  -m 256 -cpu max \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0 \
  -device vhost-vsock-pci,guest-cid=3 \
  -append "netperf -- -D -f -4 -p 12865"
