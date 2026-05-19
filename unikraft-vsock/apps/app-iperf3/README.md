# iperf3 for Unikraft

This project ports **iperf3 3.19.1** to Unikraft.

## Usage

Configure and build:

```bash
cd app-iperf3/

./defconfig.sh
./create_rootfs.sh
make -j`nproc`
```

Run:

```bash
./iperf3.sh
```

Run on tap0:
1. turn on a virtual netword card tap1, and run `dnsmasq` background. install some modules if needed.
```bash
ip tuntap add dev tap0 mode tap
ip link set dev tap0 up
ip addr add 172.44.0.1/24 dev tap0
dnsmasq -d -i tap0 --bind-dynamic --dhcp-range=172.44.0.2,172.44.0.2,255.255.255.0,12h &
```
2. run iperf3 server using `iperf3_tap0.sh`
```
./iperf3_tap0.sh
```
