#!/bin/bash
set -x

KERNEL="app-iperf3_qemu-arm64"
# Server, IPv4
ARGS="-s -4"

qemu-system-aarch64 \
        -M virt,gic-version=3 \
        -cpu max \
        -kernel $KERNEL \
        -append "-- ${ARGS}" \
        -nographic \
        -device virtio-net-pci,netdev=net0 \
        -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
        -device virtio-rng-pci

