# Porting netperf to Unikraft（+ vsock 整合）— 專案報告

## 摘要

本專案把 [netperf 2.7.0](https://github.com/HewlettPackard/netperf) 的 server
端（`netserver`）移植到 [Unikraft](https://unikraft.org) 0.21.0 unikernel
框架上，並進一步整合 vsock transport，讓同一份 server 程式碼可以選擇走
TCP（virtio-net + lwIP）或 AF_VSOCK（virtio-vsock）。

第一階段把 TCP netperf 跑起來，過程中修了 Unikraft / lwIP / netperf 三邊
共五個 bug；第二階段參考 `unikraft/app-iperf3` 的 vsock 整合方式，加上自己
寫的兩個 shim 修補（因為 netperf 用到了 iperf3 沒踩過的 socket API），完
成 host ↔ unikernel-guest 的 vsock 端到端通訊。

最終支援三種 build：

| Mode | Target | 用途 |
|---|---|---|
| x86_64 TCP | `qemu-system-x86_64` | 主要 throughput benchmark |
| arm64 TCP | `qemu-system-aarch64 -M virt` | arm64 對照 / 部署到 arm64 實機 |
| arm64 vsock | `qemu-system-aarch64 -M virt` | vsock transport 比較 |

`apps/netperf/` 下的 netperf 應用程式碼在整個過程**完全沒動**；所有改動
集中在 build 設定、kernel patches、以及 vsock shim。

---

## 1. 動機與目標

**Class project（CSIE 5310）目標**：量 Unikraft unikernel 跟全功能 Linux/KVM
guest 在 netperf 下的 TCP/UDP throughput 與 latency 差距，看 unikernel 拿
掉 process / VFS / 大半 syscall layer 之後是否拿得到實質效能優勢。

**進一步動機（vsock）**：virtio-net + lwIP 中間隔了完整的 TCP/IP stack；
vsock 是 host ↔ guest 之間的點對點 socket transport，理論上跳過 IP/TCP
這層應該更快。本專案想驗證這個假設在 netperf 工作負載下的實際幅度。

**為什麼選 netperf**：

- 有 TCP_STREAM、TCP_RR、UDP_STREAM、UDP_RR 四個面向，能同時量 throughput
  跟 latency。
- 是 class 課程指定的工具之一，方法學有參考。
- 比 iperf3 經典、命令行可控性高。

---

## 2. 系統概覽

```
   ┌─────────────────────┐     control conn (12865)     ┌──────────────────┐
   │  Host (Linux KVM)   │ ◄──────────────────────────► │  Unikraft guest  │
   │                     │                              │                  │
   │  netperf            │     data conn (TCP_STREAM:   │  netserver       │
   │  (stock 2.7.0)      │      1 KB/8 KB/64 KB msgs)   │  (ported)        │
   │                     │ ◄──────────────────────────► │                  │
   └─────────────────────┘                              │  ┌────────────┐  │
                                                        │  │   lwIP     │  │
   transport 一：virtio-net + TCP                       │  └────┬───────┘  │
   transport 二：virtio-vsock + socat bridge            │  ┌────┴───────┐  │
                                                        │  │ virtio-net │  │
                                                        │  │ virtio-vsk │  │
                                                        │  └────────────┘  │
                                                        └──────────────────┘
```

Unikernel 端只跑 `netserver`；netperf client 永遠在 host 上。三個 build
mode 的差別只在 unikernel 怎麼把 socket 訊息送出去：

- **TCP（x86_64 / arm64）**：netserver 用 lwIP 走 TCP，QEMU 用 virtio-net 帶
  進帶出。
- **vsock（arm64）**：Unikraft 在 `posix-socket` 層攔截 `socket(AF_INET, SOCK_STREAM)`
  並透明換成 `AF_VSOCK`，QEMU 用 `vhost-vsock-device` 直接接到 host 的
  vhost-vsock driver。

---

## 3. Phase 1 — 把 netperf 跑在 Unikraft 上

### 3.1 工程挑戰

- **沒 fork**：netserver 預設行為是 `accept()` 後 fork 一個 child 處理連線；
  Unikraft 沒這個。
- **沒 daemonize**：netserver 預設想 detach 成 daemon；unikernel boot 後就
  是它自己，detach 沒意義。
- **沒 CPU util 量測**：netperf 用 `/proc/stat` / `kstat` 算 CPU
  使用率，unikernel 都沒有。
- **lwIP ≠ Linux socket layer**：很多 `setsockopt`/`getsockopt` 行為跟 Linux
  不同甚至沒實作，netperf 假設 Linux 行為就會炸。

### 3.2 整體做法

寫一個 thin glue layer：

- `apps/netperf/Makefile.uk`：選擇要編進去的 netperf 原始碼檔案
  （`netserver.c`、`netlib.c`、`netsh.c`、`nettest_bsd.c`、`nettest_omni.c`、
  `netcpu_none.c`、`dscp.c`、`net_uuid.c`），關掉 `-DDO_IPV6=0`、`-fcommon`
  等 build flags。
- `apps/netperf/glue.c`：擁有 `main()`，把 `netserver_main` 包起來，提供
  預設 argv（`-D -f -4 -p 12865`）。
- `apps/netperf/Config.uk` / `defconfig`：把需要的 Unikraft 子系統（lwIP、
  musl、virtio-net、posix-poll、ukmmap、schedcoop、ukrandom、...）一次選齊。
- `apps/netperf/include/config.h`：autoconf shim，把 netperf 假設的
  `HAVE_*` 巨集都定義出來。

### 3.3 五個非寫不可的修補

過程中發現五個會讓 boot 或測試直接掛掉的問題，每個都要動手修。

#### Bug 1 — `init_posix_tty` / `init_tty_cons` 從來沒被執行過

**症狀**：unikernel boot 完之後完全沒輸出；第一個 `fprintf` 回 `EBADF`，
後續 fd lookup 觸發 assertion。

**Root cause**：Unikraft 的 init table 是用 section name 排序的。`UK_PRIO_AFTER(UK_PRIO_AFTER(UK_FS_PRIO_FSAVAIL))`
這個巨集鏈在 `__section(".uk_inittab" #base #prio)` 裡，因為
**stringify-before-expand** 的 C 巨集規則，token 沒有被展成數字就被字串化，
section 名稱變成 `.uk_inittab4__UK_PRIO_AFTER___UK_PRIO_AFTER_UK_FS_PRIO_FSAVAIL`，
linker 不會把它 merge 進 `.uk_inittab`，整個 init 函式直接被跳過。

**修補**：把 `UK_FS_PRIO_FSAVAIL` 換成寫死的數字 `2`。

- 檔案：`unikraft/lib/posix-tty/tty.c`
- 修改：`uk_rootfs_initcall_prio(init_posix_tty, 0x0, 2)`
- 對應 patch：`patches/0001-unikraft-posix-tty-init-priority.patch`

#### Bug 2 — lwIP 的 `RECV_BUFSIZE_DEFAULT = INT_MAX`

**症狀**：TCP_STREAM 第一輪測試在 `virtqueue_ring_interrupt` 裡 crash，
register 還顯示 `rdi = "netperf\0\0"`。

**Root cause**：lwIP 的 `opt.h:2031` 把 `RECV_BUFSIZE_DEFAULT` 設成 `INT_MAX`
（約 2 GiB）。netperf 透過 `getsockopt(SO_RCVBUF)` 讀回這個值當 receive
buffer size，OMNI 測試的 default-fill loop 真的寫了 2 GiB 的 `"netperf"`
字串到一個只有 16 KiB 的 buffer 裡，把 heap 上的 virtio queue descriptors
寫壞，下次中斷就死。

**修補**：override 成 `TCP_WND`（262142）。

- 檔案：`libs/lwip/include/lwipopts.h`
- 對應 patch：`patches/0002-lwip-rcvbuf-default.patch`

#### Bug 3 — lwIP 沒實作 `getsockopt(SO_SNDBUF)`

**症狀**：每次新連線 console 都印
`netperf: get_sock_buffer: getsockopt SO_SNDBUF: errno 92`（`ENOPROTOOPT`）。
netperf 把 `-1` 存到 `effective_sizep`，下游 buffer-ring 算術 wrap 到約 2 GiB。

**修補**：patch netperf 的 `src/netlib.c` 裡的 `get_sock_buffer`，`getsockopt`
失敗時回 16384 作為合理 default，並在非 debug 模式下抑制錯誤訊息。

- 對應 patch：`apps/netperf/patches/0002-sndbuf-fallback.patch`

#### Bug 4 — `allocate_buffer_ring` 沒檢查 caller 輸入

**症狀**：和 Bug 2 同類型的 overflow，當作 defense-in-depth。

**Root cause**：`allocate_buffer_ring()` 直接信任 caller 給的 `width`、
`alignment`、`offset`、`buffer_size`，alignment 不是 2 的冪、size 太大時
寫穿 buffer。

**修補**：四個參數全部 clamp 到合理範圍（width ∈ [1,1024]、alignment 2 的
冪 ∈ [1,4096]、offset ∈ [0,alignment)、buffer_size ∈ [1,16 MiB]）。

- 對應 patch：`apps/netperf/patches/0003-allocate-buffer-ring-sanitize.patch`

#### Bug 5 — netserver 在 accept 時想 `fork()`

**症狀**：第一個 incoming connection 觸發 `clone()` stub warning，連線無人
處理。

**修補**：patch `init_netserver_globals()`，強制
`spawn_on_accept = 0, want_daemonize = 0, not_inetd = 1`，並把 `main` 改名為
`netserver_main` 讓 `glue.c` 包它。

- 對應 patch：`apps/netperf/patches/0001-unikraft-stubs.patch`

### 3.4 Phase 1 驗證結果

x86_64，TCG，single vcpu：

| 測試 | x86_64 user-mode | x86_64 tap+vhost |
|---|---:|---:|
| TCP_STREAM 1 KB msg | 443 Mbps | **4156 Mbps** |
| TCP_STREAM 8 KB msg | 1439 Mbps | **3357 Mbps** |
| TCP_STREAM 64 KB msg | 548 Mbps | **3450 Mbps** |
| TCP_RR 1 KB req/resp | 2630 trans/sec | **7179 trans/sec** |

arm64（從 x86 host cross-compile，TCG 跑）：TCP_STREAM 1 KB msg = 2813 Mbps。

tap + vhost-net 比 user-mode 快約 7 倍；以下 vsock benchmark 也都用 tap +
vhost-net 作為 TCP baseline。

---

## 4. Phase 2 — 整合 vsock

### 4.1 為什麼是 vsock

`virtio-vsock` 是 host ↔ guest 之間的點對點 socket transport：

- 不需要 IP / port allocation / routing；CID + port 直接定址。
- 不經過 lwIP TCP stack 的封裝 / state machine。
- 不經過 host 的 bridging / iptables / netfilter。
- 跟 vhost-net 一樣有 `vhost_vsock` kernel module 做 zero-copy 加速。

理論上對 throughput 與 latency 都有幫助；本專案想實際量量看。

### 4.2 參考 — `unikraft/app-iperf3`

[`NatsuCamellia/unikraft`](https://github.com/NatsuCamellia/unikraft) 的
`vsock` 分支已經把 vsock device library（`lib/ukvsockdev`）、virtio-vsock
driver（`drivers/virtio/vsock`）、AF_VSOCK posix-socket driver 都做好了，
並在 `lib/posix-socket/socket.c` 裡放了一個透明 shim：

```c
// posix-socket/socket.c:320
if (family == AF_INET && type == SOCK_STREAM) {
    struct posix_socket_driver *vsock_driver = posix_socket_driver_get(AF_VSOCK);
    void *vsock_data = posix_socket_create(vsock_driver, AF_VSOCK, type, 0);
    ...
    al->stub_node = al->node;    // keep the AF_INET (lwIP) socket as stub
    al->node = (struct posix_socket_node){ vsock_driver, vsock_data };
}
```

只要 kernel 編了 `CONFIG_LIBUKVSOCKDEV=y`，**所有** `socket(AF_INET, SOCK_STREAM)`
都會被換成 `AF_VSOCK`。應用程式（不管是 iperf3 還是 netperf）完全無感
—— 它以為自己在開 TCP socket，實際走 vsock。

`apps/app-iperf3` 用這個 kernel 跑 arm64 + virtio-mmio + vhost-vsock 已經
驗證可動。我們就把這份 vendored 到 `unikraft-vsock/`，讓 netperf 用同一個
kernel。

### 4.3 為什麼是 arm64：x86 那邊撞牆

理論上想在 x86 KVM 上跑 vsock（host 本來就 x86，速度最快）。實作上撞到：

```
PCI 00:04.00 (0700 1af4:1053): driver 0x272b00
ERR: [libvirtio_pci] Invalid Virtio Devices 1053
ERR: Failed to probe (legacy) pci device: -22
```

**Root cause**：

- `virtio-vsock` 是 **modern-only** 的 virtio device（PCI device id `0x1053`，
  落在 modern range `0x1040–0x107f`）；它沒有 legacy 版本，QEMU 的
  `vhost-vsock-pci` 永遠以 modern 形式呈現。
- Unikraft 的 virtio-pci driver（`drivers/virtio/pci/virtio_pci.c:374`）**只
  實作了 legacy**：`if (pci_dev->id.device_id < 0x1000 || pci_dev->id.device_id > 0x103f)`
  直接拒掉。原始碼註解明寫 “modern PCI device ... in the future”。

也就是說 vsock 沒辦法在 x86 `pc` 機器的 PCI bus 上 probe。

三條解法各自評估：

| 路徑 | 可行性 | 速度 | 工作量 |
|---|---|---|---|
| **A. arm64 + virtio-mmio**（照 iperf3 做法） | ✅ 現成 | TCG → 慢；arm64 KVM → 快 | 低 |
| B. x86 + QEMU microvm + virtio-mmio + KVM | 需 Unikraft 改 microvm boot proto | KVM 原生 | 中高 |
| C. 自己幫 Unikraft 補 modern virtio-pci driver | 重新寫 driver | KVM 原生 | 高 |

選 **Path A**，理由：

1. 完全照 iperf3-unikraft 跑得起來的路徑走，風險最低。
2. 專案的終極部署目標就是 arm64 實機；現在 x86 TCG 是過渡。實機跑時直接
   `-enable-kvm` 即可。
3. Class project 時間有限，先把 vsock pipeline 端到端打通，B / C 留待
   後續。

### 4.4 修了原本 unikraft-vsock 哪些東西

> 這節對應到題目「修了原本 unikraft-vsock 什麼東西」的具體答覆。

整合過程發現 `unikraft-vsock` 的 vsock shim 是為 iperf3 設計的，**iperf3 用到
的 socket API 比 netperf 少**，所以 netperf 一上來就踩到兩個沒處理的洞。
這兩個都修在
`unikraft-vsock/unikraft/lib/posix-socket/socket.c`：

#### Fix 1 — 強制 `protocol = 0`

**症狀**：netperf 的 OMNI server 呼叫
`socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)`（`res->ai_protocol = IPPROTO_TCP = 6`）。
原本的 shim 把 `protocol=6` 整個轉發給 `posix_socket_create(AF_VSOCK, ...)`，
而 virtio-vsock driver 在 `virtio_vsock.c:1167` 只接受 `protocol = 0`，回
`-EPROTONOSUPPORT`。vsock socket 建立失敗，shim 沒處理錯誤就直接落到 lwIP
TCP，data socket 跑到 lwIP TCP port 12866 而**不是** vsock 12866 ——
host 的 socat bridge 怎麼都連不上。

iperf3 沒踩到這個是因為它的 `socket()` 呼叫位置不會帶 `IPPROTO_TCP`（多數
是 `protocol=0`）。

**修補**：shim 在建 vsock backing socket 時，**強制 `protocol = 0`**。
AF_VSOCK 有自己的 protocol 空間，AF_INET 那邊的 `IPPROTO_TCP` 對它而言
沒意義。

```c
// 修改前
void *vsock_data = posix_socket_create(vsock_driver, AF_VSOCK, type, protocol);

// 修改後
void *vsock_data = posix_socket_create(vsock_driver, AF_VSOCK, type, 0);
```

位置：`unikraft-vsock/unikraft/lib/posix-socket/socket.c:328`。

#### Fix 2 — 攔截 `getsockname` 翻譯 `sockaddr_vm` → `sockaddr_in`

**症狀**：Fix 1 後，data socket 確實建在 vsock 12866 上了，但 client 試
連時 server 卻說 `telling the remote to call me at 0`。client 拿到
`data_port = 0`，連 port 0，timeout。

**Root cause**：netperf 的 OMNI server 在 `listen()` 之後做：

```c
getsockname(s_listen, (struct sockaddr *)&myaddr_in, &addrlen);
omni_response->data_port = ntohs(((sockaddr_in *)&myaddr_in)->sin_port);
```

它預期 `myaddr_in` 是 `sockaddr_in` 結構、`sin_port` 在 offset 2。但 vsock
socket 的 `getsockname` 回傳的是 `sockaddr_vm`：

| offset | sockaddr_in | sockaddr_vm |
|---|---|---|
| 0–1 | `sin_family` | `svm_family` |
| 2–3 | `sin_port` | `svm_reserved1`（永遠 0）|
| 4–7 | `sin_addr` | `svm_port` ← port 真的在這裡 |

netperf 從 offset 2 讀到的永遠是 0，所以告訴 client 的 port 也是 0。

iperf3 沒踩到，因為 iperf3 自己會記住 listen 時用的 port，不靠
`getsockname` 回報。

**修補**：shim 攔截 `getsockname` syscall，如果 socket 是 shim 包過的
（`al->stub_node.driver != NULL`），就把 vsock 的 `sockaddr_vm` 翻譯成
`sockaddr_in` 再交給呼叫者：

```c
struct sockaddr_vm addr_vm;
socklen_t vm_len = sizeof(addr_vm);
posix_socket_getsockname(of->file, (struct sockaddr *)&addr_vm, &vm_len);
struct sockaddr_in addr_in = {
    .sin_family = AF_INET,
    .sin_port   = htons((__u16)addr_vm.svm_port),
    .sin_addr   = { .s_addr = 0 }
};
memcpy(addr, &addr_in, MIN(*addr_len, sizeof(addr_in)));
*addr_len = sizeof(addr_in);
```

位置：`unikraft-vsock/unikraft/lib/posix-socket/socket.c:632`～`658`
（getsockname syscall 整段重寫）。

#### 順帶：把 netperf port 用到的兩個 patch 也套到 vendored 樹

`unikraft-vsock/unikraft/` 是 vendored 進 repo 的，不像主要的
`unikraft/` 會被 `setup.sh` 套 patch。所以也手動把以下兩個 patch 套上：

- `patches/0001-unikraft-posix-tty-init-priority.patch` → `unikraft-vsock/unikraft/lib/posix-tty/tty.c`
- `patches/0002-lwip-rcvbuf-default.patch` → `unikraft-vsock/libs/lwip/include/lwipopts.h`

沒套這兩個的話，分別會 boot 不出 console、跑 TCP_STREAM 會炸。

### 4.5 Host 端 socket bridge

host 上的 netperf 是 stock 版只會講 TCP，guest 那邊在 AF_VSOCK 上 listen，
中間需要橋接。用 `socat` 起兩個 forwarder：

```bash
# 控制連線：host TCP 22865  →  guest vsock 3:12865
socat TCP4-LISTEN:22865,bind=127.0.0.1,reuseaddr,fork VSOCK-CONNECT:3:12865

# 資料連線：host TCP 12866  →  guest vsock 3:12866
socat TCP4-LISTEN:12866,bind=127.0.0.1,reuseaddr,fork VSOCK-CONNECT:3:12866
```

兩個 port 不同因為 host 已經有一個 `netserver` service 在 12865 上跑，所
以 control 端避開用 22865；data 端 pin 在 12866 是 `netperf -- -P ,12866`
告訴 server 要 bind 哪裡，host 端 socat 必須對齊。

### 4.6 Phase 2 驗證結果

arm64 從 x86 host cross-compile，QEMU TCG 跑，host netperf 經 socat bridge：

| 測試 | arm64 + vsock (TCG) |
|---|---:|
| TCP_STREAM 1 KB msg, 5 s | 265 Mbps |
| TCP_RR 1 B req/resp, 3 s | **3609 trans/sec** |

絕對數字偏低（arm64 TCG 模擬 + vsock `getsockopt` 不支援 SO_RCVBUF 退到
16384 buffer + socat bridge 多一層 copy），但**端到端 pipeline 完全打
通**：

- virtio-vsock 在 virtio-mmio 上成功 probe。
- vsock shim 把所有 `AF_INET` TCP 轉成 `AF_VSOCK`。
- netperf 沒被改一行原始碼，控制連線、資料連線、結果回傳都正確跑完。

實機 arm64 + KVM 跑時，bottleneck 就不是 CPU emulation，vsock 與 TCP 的
transport 差異才會真正浮出來。

---

## 5. Build 系統與檔案配置

三個 build mode 對應三個 output 目錄，互不干擾：

```
apps/netperf/
├── netperf.defconfig             ← x86_64 TCP  →  make           →  build/
├── netperf.arm64.defconfig       ← arm64  TCP  →  build_arm64.sh →  build-arm64/
└── netperf.arm64.vsock.defconfig ← arm64  vsk  →  build_vsock.sh →  build-vsock/
```

`build_vsock.sh` 不指向主 `unikraft/` 樹（那是 upstream，沒 vsock），而是
指向 vendored 的 `unikraft-vsock/unikraft/`（vsock-enabled）並把
`musl` + `lwip` 也從 `unikraft-vsock/libs/` 拿，只有 `compiler-rt` 重用主
樹的（因為 compiler-rt 跟 kernel 版本無關）：

```bash
UK_VSOCK="$ROOT/unikraft-vsock/unikraft"
LIBS="$ROOT/unikraft-vsock/libs/musl:$ROOT/libs/compiler-rt:$ROOT/unikraft-vsock/libs/lwip"
make -C "$UK_VSOCK" A="$APP" L="$LIBS" O="$BUILD_DIR" C="$CONFIG" \
    CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc)
```

Patches 分兩批：

| 套到 | 套的時機 | 套的內容 |
|---|---|---|
| `unikraft/`（cloned） | `setup.sh` 跑時 | `patches/0001*` + `patches/0002*` |
| `libs/lwip/`（cloned） | `setup.sh` 跑時 | `patches/0002*` |
| `unikraft-vsock/unikraft/` + `unikraft-vsock/libs/lwip/`（vendored） | commit 進 repo | 同上兩個 patch 直接 commit 到 vendored 樹 |
| `apps/netperf/build*/appnetperf/origin/`（netperf source 解壓的地方） | Unikraft 的 build hook 自動 | `apps/netperf/patches/0001..0003*` |

---

## 6. Benchmark 驗證

| 測試 | x86 TCP user-mode | x86 TCP tap+vhost | arm64 TCP tap+vhost | arm64 vsock (TCG) |
|---|---:|---:|---:|---:|
| TCP_STREAM 1 KB | 443 Mbps | **4156 Mbps** | 2813 Mbps | 265 Mbps |
| TCP_STREAM 8 KB | 1439 Mbps | 3357 Mbps | — | — |
| TCP_STREAM 64 KB | 548 Mbps | 3450 Mbps | — | — |
| TCP_RR 1 KB | 2630 t/s | **7179 t/s** | — | — |
| TCP_RR 1 B | — | — | — | **3609 t/s** |

注意：

- x86 數字都是 TCG single vcpu 下量的；換 KVM 會更高。
- vsock 數字是 arm64 在 x86 host 上 TCG 跑出來的；arm64 KVM 上會顯著
  上升，且能跟 arm64 TCP（tap+vhost）做公平的同平台比較。
- 完整的 benchmark 矩陣（TCP vhost on/off vs vsock，多種 message size）
  還沒跑完，是後續工作。

---

## 7. 限制與未來工作

- **沒 x86 vsock**：需要 Unikraft 補 modern virtio-pci driver（約 400 行
  的 driver port），是後續最有價值的 follow-up。
- **`vhost-vsock` 沒有 off**：QEMU 的 vsock 裝置永遠走 `vhost_vsock` kernel
  driver，沒有純 userspace 對照組。因此 vsock 那格只有一個 data point。
- **`setitimer` / `SIGALRM` stubbed**：server 端測試時長 timer 不會觸發；
  靠 client close socket 觸發 EOF 收尾，正常 client 不受影響。
- **`spawn_on_accept = 0`**：一次只能服務一個 client，並發測試會排隊。
- **沒 CPU util 量測**：netperf 印 `-1.00`；要量 CPU 使用率要另外用
  host 端工具（如 `pidstat`）。
- **arm64 跑在 x86 TCG 上很慢**：絕對數字參考價值有限；正式 benchmark
  需要 arm64 實機。
- **沒測 preemptive scheduler**：只跑 `LIBUKSCHEDCOOP`；換 `LIBUKSCHED`
  是否影響 latency 還沒測。

---

## 8. 致謝與參考

- [`unikraft/app-iperf3`](https://github.com/unikraft/app-iperf3) — vsock shim
  的原始參考實作，本專案的 vsock kernel 直接 vendor 自其使用的
  `NatsuCamellia/unikraft` vsock branch。
- [HewlettPackard/netperf](https://github.com/HewlettPackard/netperf) 2.7.0
  上游原始碼。
- [Unikraft](https://unikraft.org) 0.21.0 (Ijiraq) kernel。
