set -x

KERNEL=./build/app-iperf3_qemu-arm64
# Server, IPv4
ARGS="-s -4"

qemu-system-aarch64 \
	-M virt,gic-version=3 \
	-cpu max \
	-kernel $KERNEL \
	-append "-- ${ARGS}" \
	-nographic \
	-device virtio-net-pci,netdev=net0 \
	-netdev user,id=net0,hostfwd=tcp::5201-:5201 \
	-device vhost-vsock-device,bus=virtio-mmio-bus.0,guest-cid=3 \

