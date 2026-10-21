# 去重加速

Codex 这类客户端每一轮都会把整段对话历史重新上传。去重加速在路由器上把这些请求里已经传过的内容换成短引用，出口服务器再还原，所以跨境上行只传新增的部分。

默认关闭。关闭时生成的 sing-box 配置与没有这个功能时逐字节相同。

## 组成

- 路由器：`stargate-dedup` 前端，即 anytls-go 的 `cmd/dedup`。Stargate 不保存其源码：`sh tools/dedup/build.sh` 从 `zji996/anytls-go` 的固定提交拉取并构建到 `.local/dedup-build/`，不使用 `third_party/`；升级时修改脚本里的提交。由 `/etc/init.d/stargate-dedup` 管理，LuCI 包不带该二进制。
- 出口服务器：anytls-go 的 `dedup back` 解码端，加上带 `-dedup-backend` 参数的 anytls-server。没有解码端的节点照常工作，前端对它们原样转发。

## 开关

```sh
/usr/share/stargate/dedup.sh on 10.0.0.12   # 打开，只对这些设备（IP 或网段）生效
/usr/share/stargate/dedup.sh off            # 关闭
/usr/share/stargate/dedup.sh status         # 开关、前端、压缩率
/usr/share/stargate/dedup.sh ca             # 打印设备需要信任的 CA 证书
```

`on` 会先启动前端，再让 Stargate 重新生成并应用路由；`off` 顺序相反。失败时恢复原来的开关、设备列表、前端运行和自启状态；如果已尝试切换路由，会重新应用旧运行态，不能仅凭配置文件相同跳过恢复。恢复本身失败会明确报错，并保留仍可能被路由使用的前端。每次切换都会重启一次 Stargate，正在走代理的连接会断开一次。

不带设备参数时沿用上次保存的设备列表。

## 前提

- 列出的设备必须先信任 `dedup.sh ca` 输出的证书。否则打开后，这些设备访问 OpenAI 会报证书错误。CA 在第一次 `on` 时生成，只能为 `domains` 里的域名签发证书。
- 只接管列出的设备访问这些域名的 443 端口 TCP 连接，其他设备和流量不受影响。
- 路由模式为直连时没有可去重的流量，`on` 会拒绝执行。

## 出口不变

主节点算一个通道，每个带专用端口的节点各算一个。连接原本走哪个节点，前端就从哪个节点出去，出口 IP 不变。sing-box 用 SOCKS 用户名区分通道：

- 连接通过 `dedup-out-<通道>` 进入前端；
- 前端经回程入站 `dedup-in` 带着同一个用户名返回；
- `auth_user` 规则再把它送回该通道的节点。

增删节点不需要重启前端。

## 资源

前端从 anytls-go `2bb41fe` 起每个请求预留 2 倍正文（此前 3 倍），预算不足时最多等 3 秒再原样转发；新内容在解码端应答前不被其他请求引用，帧丢失时撤销，避免整包重发。

所有通道合计受 cgroup 内存上限约束，默认 300 MiB，超出时内核杀掉前端，不会杀 sing-box。前端崩溃后 1 秒内由 procd 拉起。前端参数变化时，新进程先启动，旧进程再继续接收 3 秒，期间不断流。

## 可选项

UCI `stargate.dedup` 段，一般不需要改：

| 选项 | 默认 | 说明 |
| --- | --- | --- |
| `domains` | `chatgpt.com api.openai.com` | 接管的域名，含子域名；改动后需删除 `/etc/stargate/dedup` 让 CA 重建，设备重新信任 |
| `port` | `10860` | 前端端口；加 1 是回程入站，加 2 是统计接口 |
| `memory_mib` | `300` | 内存上限，索引和在途预算按比例缩放 |
| `index_mib` | 空（按 `memory_mib` 缩放，300 时为 230） | 前端认为解码端持有的内容量，设为解码端 `cache-mib` 的约 90%；只存哈希，按实测平均块约 9 KiB 计约占 1/40，最坏 1/8 |
| `compress` | `auto` | 新内容的压缩：`auto`、`huffman`（更省 CPU）或 `off`（只去重） |

## 2026-10-21：6.1 实机验收

实验仅在 S20M 测试路由器进行，客户端为同一 LAN 的实验设备。活动节点未切换；实验 AnyTLS 服务、解码端与 HTTPS origin 都只监听 loopback。没有部署到生产路由器、DMIT 或 Sub2API。

已实际通过：

- 部署后保持关闭，`generate` 结果与原运行配置逐字节相同；启用后服务正常、前端硬内存上限为 `314572800` 字节。
- 客户端 → 实验专用端口 → 单前端 → `dedup-in` 用户名回程 → 实验 AnyTLS → 解码端 → HTTPS origin。连续三次上传同一份 `1,048,633` 字节 JSON，origin 返回的长度与 SHA-256 三次均正确。
- 前端统计 `original_bytes=3145899`、`sent_bytes=796800`、`ratio=3.948166`，三次均使用去重帧。这是合成正文的帧计数，不含 TLS/AnyTLS 开销，也不是实测跨境带宽收益。
- 同一前端的另一个实验通道不提供解码端，客户端仅信任 origin 证书也能成功上传，正文哈希一致，说明该通道原样转发。删掉该实验节点后再次 `on`，前端 PID 不变。
- `off` 后配置逐字节回到带实验节点的关闭基线，撤销分流后才停止前端并禁用自启。
- 分别对 `on`、`off` 注入一次运行态失败：先停止 Stargate，再返回失败。CLI 返回非零，随后恢复原开关、配置、服务与 nft 表；失败 `on` 的前端也正确停止并恢复原自启状态。

本地 `tests/dedup-switch.sh` 使用真实开关函数与隔离的 UCI/init/runtime 替身，覆盖启停、重复启用、CA/前端启动失败、设备列表恢复、选项不存在与空值、运行态失败、返回成功但回滚旧配置、前端停止失败。由 `sh manage.sh check` 自动执行。

首轮实验未覆盖 LAN 无应用代理的透明路径，后续补测见下节。首轮实验域名只在路由器 hosts 中可解析：关闭后测试 origin 使用客户端连接地址覆盖，不能把实验域名的公共 DNS 失败解释成开关失败。

## 同日扩展验收：保持启用

按用户要求打开测试路由器的开关，仅选择 LAN 实验客户端，域名保持默认的 `chatgpt.com api.openai.com`。实验结束后保留启用状态，设备列表和 CA 保留；实验节点、进程、地址、域名解析及临时服务环境全部撤销，运行配置重新由 CLI 正常生成。

实际通过的扩展项目：

- 普通配置下的 LAN 无应用代理 HTTPS：Google 204、OpenAI 未认证接口 401，TLS 验证均通过；ChatGPT TLS 通过，但站点返回 403，不能据此宣称业务可用。
- 为合成实验域名临时指定实验通道和 hosts DNS，未切换活动节点。客户端经真实 LAN redirect 入站、TLS sniff、同一前端、用户名回程、实验 AnyTLS 和解码端到 origin，三次重复正文长度/哈希正确，帧计数 ratio 为 3.95。临时路由只绑定合成域名；这些正文未发送到 OpenAI。
- 用 CLI 把实验客户端移出设备列表，重建同一实验域名配置后，同一路径成功使用原站证书上传；仅信任前端 CA 时按预期拒绝原站证书，实验通道计数完全不变，确认设备排除生效。随后恢复原设备列表。
- 专用 HTTP/SOCKS 端口、HTTP/1.1/HTTP/2、重复正文、增长正文、四路并发共八次请求，以及持续五秒且包含全部十个分段的流式回复，正文哈希均正确。综合十五次去重请求累计原文 `15741812` 字节、帧计数 `853298` 字节，ratio 为 18.45；该结果来自重复合成数据，不代表真实业务收益。
- 无解码端的实验出口正常原样转发；前端 CA 不受信任时，启用拦截的通道按预期报证书校验错误。
- 解码端停止时，已建立的 HTTP/1.1 TLS keepalive 连接仍成功上传；冷重启解码端后，同一连接重新去重且正文正确。实验前端通过仅作用于该服务的临时 CA 环境信任自签 origin，验证后已恢复服务文件和环境。
- 强制杀掉前端后 procd 实测约 1.53 秒恢复，随后上传正确；cgroup 上限确认为 300 MiB，验收时 OOM 计数为零。
- 主节点和现有专用端口通过同一 HTTPS trace 接口核对，`on`/`off` 出口地址分别保持一致。清理实验后再次 `off`，配置与本轮开始前逐字节相同；最后再次 `on`，配置也与清理后的启用基线逐字节相同。

WSL 系统 DNS 经 Windows 隧道返回过错误地址；直接查询路由器受管 DNS 能得到正常地址。透明 HTTPS 测试使用受管 DNS 结果，未修改 WSL/Windows DNS 设置。

当时 6.1 的真实出口尚无解码端，实际 OpenAI 流量仍原样转发。生产启用见下节。

## 2026-10-22：8.1 生产启用

生产路由器（GL-MT6000，OpenWrt 24.10.0-rc2，sing-box 1.13.11），主节点与专用端口 `dmit-69` 都指向已部署解码端的 DMIT `69.63.200.32`。设备只选 Sub2API 主机，其 OpenAI OAuth 账号有直连（经透明代理）和经 `dmit-69` HTTP 端口两种，都进入 `main` 通道。

部署：

- 只增量上传前端二进制（Go 1.27.2，arm64）、`stargate-dedup` init、`dedup.sh` 及同步后的 `stargate.sh`、`lib/config.sh`、`lib/maintenance.sh`；LuCI 与远控组件未动。关闭状态下 `generate` 与运行配置逐字节相同。
- 先用 `stargate-dedup ca` 生成 CA，设备信任后再 `on`，避免证书错误窗口。`/etc/stargate/dedup/` 已加入 `sysupgrade.conf`。

设备侧 CA 自动同步（Sub2API 主机，Ubuntu 24.04）：

- 叶子证书由前端签发，7 天有效、到期前一天自动重签，设备无需操作；CA 10 年有效，只在重刷、改域名或手动轮换时变化。
- `stargate-dedup-ca-sync.timer` 开机 2 分钟及每小时运行 `/usr/local/sbin/stargate-dedup-ca-sync`：用 `/etc/stargate-dedup-ca/` 下的专用密钥和固定主机密钥取 CA。路由器 dropbear 对该密钥强制 `command="cat /etc/stargate/dedup/ca.pem"` 并禁止转发与 PTY，实测任意命令都只返回 CA、端口转发被拒。
- 只接受单张、CA:TRUE、名称约束 critical 且恰为 `chatgpt.com api.openai.com` 的未过期证书；变化时写入 `/usr/local/share/ca-certificates/stargate-dedup.crt`、`update-ca-certificates` 并重启 `sub2api.service`（Go 只在启动时读取信任库）。取不到时保留现有证书。日志 `journalctl -t stargate-dedup-ca`。

验收：

- Sub2API 主机访问 `chatgpt.com` 证书由前端 CA 签发且校验通过；路由器本机代理端口来源得到原站证书。该主机透明、`dmit-69` 端口与路由器代理的出口地址一致。百度 200、Google 204。
- 启用后约 2 分钟真实 Sub2API 流量：原文 `118234725` 字节、帧计数 `52690640` 字节，ratio 2.24，23 帧，`fallbacks`、`resets`、`misdelivered` 均为 0。帧计数不含 TLS/AnyTLS 开销。
- 前端 cgroup 内存约 208 MiB / 300 MiB，OOM 为 0；需要继续观察高负载下是否逼近上限。

交接内存：参数或二进制变化时新旧前端在同一 cgroup 内交接。2026-10-22 升级时上限仍是单个 `memory_mib`，新前端冷启动（字面量帧大）被 cgroup OOM 杀掉一次，procd 1 秒拉起，在途请求断开。之后 init 脚本在交接时把上限临时提高到 `memory_mib` 加旧前端当前用量（以系统可用内存减 64 MiB 为限，且不低于 `memory_mib`），旧前端退出后恢复；期间若又有交接，旧的恢复不再生效。`tests/dedup-init.sh` 覆盖这些情况。2026-10-22 03:27 已随前端更新部署到 8.1，实测交接时上限 352 MiB，旧前端退出后恢复 300 MiB。

首连透传：前端的通道由首个连接创建、后台探测，因此首个连接总被原样转发；客户端长期复用的 HTTP/2 连接会整条绕过去重，8.1 曾因此约 58% 的请求未经去重。anytls-go `169a009` 起首个连接最多等待 3 秒的首次探测，已发现解码端的通道在其暂时不可达时继续拦截、逐请求直发 origin。核对覆盖率可对比前端 `framed`+`plain` 与 Sub2API `/responses` 数，并确认 `passed_conns` 不增长。

升级前端用 `tools/dedup/upgrade.sh --router root@路由器`，加 `--server root@出口` 时同时调整解码端大小：默认只预检并在路由器 `/tmp` 暂存校验（随后删除），`--apply` 先重启解码端再并行切换前端，两边缓存只冷启动一次，不重启 sing-box 与 anytls-server，失败按备份回滚。

运维注意：`on`/`off` 会重启 Stargate。本次 02:09:55 重启时 Sub2API 在途请求遇到 `connection refused`/断流，4 个 OpenAI 账号被临时停调度 10 分钟，期间请求报无可用账号，手动恢复后正常。切换应避开高峰，或先在 Sub2API 暂停相关账号再切换。Chrome/Firefox 不使用系统信任库，在该主机上用浏览器访问这些域名会报证书错误。
