# netperf 參數說明

我們在這個專案的 server / client 端用了哪些 netperf 參數、為什麼這樣選。

## 前置：netperf 的雙連線模型

netperf 跑測試時開**兩條** TCP/vsock 連線：

- **Control connection**（控制連線，預設 port `12865`）：client 把測試參數送過去、server 回 ack 與結果。
- **Data connection**（資料連線）：實際跑流量的那條。Server 端 port 通常是 ephemeral，但可以用 client 的 `-P` flag pin 住。

知道這個之後，下面的參數就直觀很多。

---

## Server 端（unikernel 裡跑的 netserver）

`apps/netperf/glue.c` 寫死的預設 args：

```
netserver -D -f -4 -p 12865
```

| flag | 意思 | 為什麼這樣選 |
|---|---|---|
| `-D` | foreground，不 daemonize | unikernel boot 後沒有 shell 把它放背景；要直接吃 console、看 log |
| `-f` | 不 spawn-on-accept（不對每條連線 fork 一個子行程） | **Unikraft 沒有 `fork()`**，必須關掉。代價：一次只服務一個 client |
| `-4` | 只接 IPv4 | lwIP 沒開 IPv6（省 image size + 避免 getaddrinfo 走錯 family） |
| `-p 12865` | 控制連線 listen 的 port | netperf 上游 default 就是 12865；沒特別理由動 |

vsock 模式跑時這幾個 flag 一模一樣 —— vsock shim 是 kernel 層做的（透明把 `AF_INET TCP` 換成 `AF_VSOCK`），netserver 自己無感。

---

## Client 端（host 上的 netperf）

我們最常用的兩條：

```
netperf -H <server> -p 12865 -t TCP_STREAM -l 5 -- -m 1024 -P ,12866
netperf -H <server> -p 12865 -t TCP_RR     -l 5 -- -r 1,1  -P ,12866
```

### `--` 前面的（控制 client 自己的行為）

| flag | 意思 | 為什麼這樣選 |
|---|---|---|
| `-H <addr>` | server 位址 | tap0 模式是 `172.31.0.2`；user-mode / vsock-bridge 是 `127.0.0.1` |
| `-p 12865` | 連到 server 的控制 port | 要跟 server `-p` 一致；vsock-bridge 場景下因 host 本機 netserver 已佔 12865，我們用 `-p 22865`（socat 橋接到 guest vsock 12865） |
| `-t TCP_STREAM` / `-t TCP_RR` | 測試類型（見下表） | — |
| `-l 5` | 跑 5 秒 | 夠久能蓋掉 warm-up burstiness；短到可以反覆跑很多輪 |

### `--` 後面的（傳給特定測試的 options）

| flag | 意思 | 為什麼這樣選 |
|---|---|---|
| `-m 1024` | TCP_STREAM 每個 `send()` 的訊息大小（byte） | 1 KB 是常見壓力點：每秒 send() 次數多、放大 per-syscall / per-packet 開銷。要做 sweep 通常還會跑 8K、64K 互相對照 |
| `-r 1,1` | TCP_RR 的 request 與 response 各 1 byte | 1 byte 是「純 round-trip 延遲」的測法 —— 把資料量降到最小，剩下的就是網路+kernel 的 latency 本身 |
| `-P ,12866` | pin **remote** (server) 的 data port 到 12866 | netperf 預設 data port 是 ephemeral，但我們的環境攔不住 ephemeral：QEMU user-mode 需要事先 `hostfwd`、vsock 場景需要事先 `socat` bridge —— 都得知道是哪個 port。pin 住 12866 後 server 就確定 bind 在 12866，前面的 hostfwd / socat 跟著對齊就行 |

---

## 兩個測試類型差在哪

| Test | 量什麼 | 流量方向 | 主要關注 |
|---|---|---|---|
| `TCP_STREAM` | **吞吐量** (Mbps) | client → server 單向灌流量 | 頻寬、buffer 設定、vhost-net 是否啟動 |
| `TCP_RR` | **每秒交易數** (trans/sec) | client ↔ server 一來一回 | round-trip 延遲、syscall 開銷、context switch 成本 |

兩個一起跑能畫出兩個面向：throughput-oriented 工作 vs latency-sensitive 工作，這也是 class-6 那套方法學常用的分法。

---

## Unikraft kernel cmdline（這不是 netperf 的 flag，但會一起出現）

run 指令會多帶這個給 unikraft kernel：

```
-append "netperf netdev.ip=172.31.0.2/24:172.31.0.1 -- -D -f -4 -p 12865"
```

- `netperf` → unikernel 自己的 argv[0]（程式名稱）
- `netdev.ip=<cidr>:<gw>` → **Unikraft libparam**，告訴 lwIP 在 tap0 上用靜態 IP（tap0 沒 DHCP server，不設就上不了網）
- `--` → 分隔線；左邊是 Unikraft 的 args，右邊是 app 的 args
- 右邊那串就是傳給 `netserver_main` 的，跟前面 server 表格一樣

如果 `-append` 只給 `"netperf"`（argv 只有 1 個），`glue.c` 會用內建的 default args（也就是 `-D -f -4 -p 12865`）。
