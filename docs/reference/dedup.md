# 去重加速

Codex 这类客户端每一轮都会把整段对话历史重新上传。去重加速在路由器上把这些请求里已经传过的内容换成短引用，出口服务器再还原，所以跨境上行只传新增的部分。

默认关闭。关闭时生成的 sing-box 配置与没有这个功能时逐字节相同。

## 组成

- 路由器：`stargate-dedup` 前端，即 anytls-go 的 `cmd/dedup`。Stargate 不保存其源码：`sh tools/dedup/build.sh` 从 `zji996/anytls-go` 的固定提交拉取并构建到 `.local/dedup-build/`，不使用 `third_party/`；升级时修改脚本里的提交。由 `/etc/init.d/stargate-dedup` 管理，LuCI 包不带该二进制。
- 出口服务器：anytls-go 的 `dedup back` 解码端，加上带 `-dedup-backend` 参数的 anytls-server。没有解码端的节点照常工作，前端对它们原样转发。
- 同一程序的 `encode`/`decode` 子命令是不拦截 TLS 的反向代理版本，edge-gateway 用它给 frp 发布的服务去重；帧格式与本页相同，升级 `build.sh` 的提交时两边一起考虑。

## 开关

```sh
/usr/share/stargate/dedup.sh on 10.0.0.12   # 打开，只对这些设备（IP 或网段）生效
/usr/share/stargate/dedup.sh off            # 关闭
/usr/share/stargate/dedup.sh status         # 开关、前端、压缩率
/usr/share/stargate/dedup.sh ca             # 打印设备需要信任的 CA 证书
/usr/share/stargate/dedup.sh configure 1 '10.0.0.12' 'api.openai.com'
/usr/share/stargate/dedup.sh configure 0 '' ''  # 关闭并清空设备和目标
```

`on` 会先启动前端，再让 Stargate 重新生成并应用路由；`off` 顺序相反。失败时恢复原来的开关、设备列表、前端运行和自启状态；如果已尝试切换路由，会重新应用旧运行态，不能仅凭配置文件相同跳过恢复。恢复本身失败会明确报错，并保留仍可能被路由使用的前端。每次切换都会重启一次 Stargate，正在走代理的连接会断开一次。

不带设备参数时沿用上次保存的设备列表。

LuCI 的 **Stargate → 去重编解码** 页面提供开关、设备（IP/网段）、目标域名和运行状态。提交直接调用同一个事务入口，失败恢复原配置和运行态；开启必须同时有设备和目标。清空目标时应取消启用。该页面使用 Lua 表单，兼容两种 LuCI 菜单入口。

`targets` 只决定哪些域名进入前端，且只能在现有 `domains` 范围内收窄（包含子域名）；未配置时兼容旧配置，沿用 `domains`。因此移除目标不会轮换 CA，也不会改变普通代理出口。关闭并清空时，UCI 保存 `targets=none` 表示没有目标，避免空选项被 UCI 丢弃后意外回退默认域名；页面显示为空。

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
| `domains` | `chatgpt.com api.openai.com` | CA 允许签发的域名（含子域名），也是前端可拦截的范围；改动要换 CA，见下节 |
| `targets` | 未设置时沿用 `domains` | 实际送去自签和编解码的目标；可收窄而无需更换 CA，`none` 表示无目标 |
| `port` | `10860` | 前端端口；加 1 是回程入站，加 2 是统计接口 |
| `memory_mib` | `300` | 内存上限，索引和在途预算按比例缩放 |
| `index_mib` | 空（按 `memory_mib` 缩放，300 时为 230） | 前端认为解码端持有的内容量，设为解码端 `cache-mib` 的约 90%；只存哈希，按实测平均块约 9 KiB 计约占 1/40，最坏 1/8 |
| `compress` | `auto` | 新内容的压缩：`auto`、`huffman`（更省 CPU）或 `off`（只去重） |
| `reverse_listen` | 空（关闭） | 反向入口的 `地址:端口`，例如 `10.0.0.1:10863`；明文 HTTP，见下节 |
| `reverse_origins` | 空 | 反向入口允许访问的上游主机，空格分隔 |

## 加目标域名

`targets` 在 `domains` 范围内，改目标只需 `dedup.sh configure`（或 LuCI 页面），重启一次 Stargate，不换 CA、设备无需操作。所以 `domains` 宜一次覆盖可能用到的大模型 API 主机，之后只改 `targets`。

只有经出口节点（有解码端）的连接能去重；直连的域名列入目标会被前端送往节点，改变出口，先确认它本来就走代理。

扩大 `domains` 要换 CA。为了让设备只重启一次客户端：

1. 在路由器另一个目录生成新 CA：`stargate-dedup ca -dir /etc/stargate/dedup.next -domains <新清单，逗号分隔>`，运行中的前端不受影响。
2. 设备同时信任新旧 CA：新 CA 装为 `stargate-dedup.crt`，旧的另存 `stargate-dedup-prev.crt`，把新清单写进 `/etc/stargate-dedup-ca/domains`（顺序与 UCI 相同），装上 `tools/dedup/ca-sync.sh`，再重启一次 Sub2API。
3. 出口解码端 `ANYTLS_DEDUP_DOMAINS` 换成新清单并重启解码端。
4. 路由器把新 CA 换入 `/etc/stargate/dedup/`，设置 UCI `domains`，再 `dedup.sh configure 1 '<设备>' '<目标>'`。
5. 设备的同步脚本取到新 CA 后自动删除 `stargate-dedup-prev.crt`，不再重启。

## 反向入口

拦截链路要求客户端信任前端 CA 并被导流，只适合改不了 `base_url` 的客户端；能改 `base_url` 的服务用反向入口：请求不带 TLS，前端按路径第一段挑上游，自己以 `https://<origin>/<其余路径>` 再发出去，同样经通道编码、共用索引和解码端。CA 不参与，名单里加主机不改证书。

- 源地址仍用 `devices`：不在其中的连接直接关闭，因此设备列表也要包含发起方（例如 Sub2API 主机）。
- `reverse_origins` 是允许的主机，顺序无关；`reverse add/remove` 会去重排序。文件里的 `#` 注释和空行改动会被下一次 `reverse add/remove` 或前端重启覆盖，长期名单以 UCI 为准。
- 凭据是 `reverse.auth`（`main:<密码>`），即 sing-box `dedup-in` 已有 `main` 用户，不新增秘密；文件 0600，只有 root 可读。
- 只转发名单内主机的 443 端口，不能当作通用 HTTP 代理。
- 解码端没列这个主机时，前端仍经同一 anytls 出口把请求发出去，只是不去重；解码端加上后 5 秒内自动切换。
- 8.12 到 8.1 这一跳是局域网明文，API key 明文经过局域网。

**开启反向入口 = 一次前端交接。** `reverse_listen` 出现在前端参数里，procd 的实例名随之改变，所以设置或清空它都会起新实例（旧实例 `-linger` 3 秒后退出，`sing-box` 不重启、CA 不动）：

前端程序还不认识 `-reverse` 时（从旧版升级），程序和这两个选项必须在同一次交接里到位，否则旧程序带着新参数起不来。用升级脚本一起做（它先装新程序、再改 UCI、核对 sing-box 配置不变后交接，失败整体恢复）：

```sh
tools/dedup/build.sh
tools/dedup/upgrade.sh --router root@ROUTER --reverse-listen 10.0.0.1:10863 \
  --reverse-origins 'api.example.com' --apply
```

程序已经支持时，也可以直接改 UCI 再交接：

```sh
uci set stargate.dedup.reverse_listen='10.0.0.1:10863'
uci set stargate.dedup.reverse_origins='api.example.com'
uci commit stargate
/etc/init.d/stargate-dedup start   # 参数变了，procd 起新实例
```

不要用 LuCI 的“保存并应用”做这一步：它会触发 Stargate 自身的 reload。

端口不能与前端的 `port`..`port+2` 及其他 Stargate 端口重复；`reverse_origins` 为空时拒绝开启。

**之后增删名单 = `reverse add/remove`，只发 SIGHUP**：名单放在 `$dedup_ca_dir/reverse-origins`（明文，0644），参数里只有路径，所以实例名不变。命令改 UCI、原子替换文件（临时文件 + `mv`，内容不变不重写）、前端在跑时 `/etc/init.d/stargate-dedup reload`（`reload_service` 只给命令行带 `-reverse` 的前端进程发 SIGHUP，不重新起实例；旧版前端没有 SIGHUP 处理，收到会退出，所以不会给它们发，此时 reload 报错并回滚名单）。不重启 `sing-box`、不重启前端、不碰 CA。失败时恢复原 UCI 与原文件，并对恢复后的文件再补发一次 SIGHUP。

```sh
/usr/share/stargate/dedup.sh reverse add api.example.com
/usr/share/stargate/dedup.sh reverse remove api.example.com
/usr/share/stargate/dedup.sh reverse list
/usr/share/stargate/dedup.sh status        # reverse 监听、名单与 reverse_* 计数
```

`reverse list` 打印 UCI 里的名单（即 `reverse add/remove` 维护的那份）。不支持删到空：要关就清空 `reverse_listen` 再交接。

### 用反向入口接入上游

把发起方账号的 `base_url` 改为 `http://<reverse_listen>/<origin>/<原路径>`，热生效，回滚就是改回原地址。例如前端监听 `10.0.0.1:10863`，原来访问 `https://api.example.com/v1/models`：

```
base_url = http://10.0.0.1:10863/api.example.com/v1
```

先在发起方上用 `curl -sS -o /dev/null -w '%{http_code}\n' http://10.0.0.1:10863/api.example.com/v1/models` 确认返回与直连一致（通常是 401），再改后台。此时链路已经可用；DMIT 解码端名单加上这个主机后才会去重：

1. 8.1：`/usr/share/stargate/dedup.sh reverse add api.example.com`（SIGHUP，前端不重启）。
2. DMIT：`/etc/anytls/dedup-domains` 加一行，`systemctl reload anytls-dedup`（SIGHUP，解码端不重启，缓存保留）。
3. 发起方后台改该账号 `base_url`。

第 2 步可以晚做：只做 1、3 时请求经同一 anytls 出口但不经去重。

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
- `stargate-dedup-ca-sync.timer` 开机 2 分钟及每小时运行 `/usr/local/sbin/stargate-dedup-ca-sync`（源码 `tools/dedup/ca-sync.sh`，路由器地址与允许的域名分别读 `/etc/stargate-dedup-ca/router` 和 `domains`；换 CA 期间路由器仍给旧 CA 时，只要它等于 `stargate-dedup-prev.crt` 就不动作）：用 `/etc/stargate-dedup-ca/` 下的专用密钥和固定主机密钥取 CA。路由器 dropbear 对该密钥强制 `command="cat /etc/stargate/dedup/ca.pem"` 并禁止转发与 PTY，实测任意命令都只返回 CA、端口转发被拒。
- 只接受单张、CA:TRUE、名称约束 critical 且恰为 `chatgpt.com api.openai.com` 的未过期证书；变化时写入 `/usr/local/share/ca-certificates/stargate-dedup.crt`、`update-ca-certificates` 并重启 `sub2api.service`（Go 只在启动时读取信任库）。取不到时保留现有证书。日志 `journalctl -t stargate-dedup-ca`。

验收：

- Sub2API 主机访问 `chatgpt.com` 证书由前端 CA 签发且校验通过；路由器本机代理端口来源得到原站证书。该主机透明、`dmit-69` 端口与路由器代理的出口地址一致。百度 200、Google 204。
- 启用后约 2 分钟真实 Sub2API 流量：原文 `118234725` 字节、帧计数 `52690640` 字节，ratio 2.24，23 帧，`fallbacks`、`resets`、`misdelivered` 均为 0。帧计数不含 TLS/AnyTLS 开销。
- 前端 cgroup 内存约 208 MiB / 300 MiB，OOM 为 0；需要继续观察高负载下是否逼近上限。

交接内存：参数或二进制变化时新旧前端在同一 cgroup 内交接。2026-10-22 升级时上限仍是单个 `memory_mib`，新前端冷启动（字面量帧大）被 cgroup OOM 杀掉一次，procd 1 秒拉起，在途请求断开。之后 init 脚本在交接时把上限临时提高到 `memory_mib` 加旧前端当前用量（以系统可用内存减 64 MiB 为限，且不低于 `memory_mib`），旧前端退出后恢复；期间若又有交接，旧的恢复不再生效。`tests/dedup-init.sh` 覆盖这些情况。2026-10-22 03:27 已随前端更新部署到 8.1，实测交接时上限 352 MiB，旧前端退出后恢复 300 MiB。

首连透传：前端的通道由首个连接创建、后台探测，因此首个连接总被原样转发；客户端长期复用的 HTTP/2 连接会整条绕过去重，8.1 曾因此约 58% 的请求未经去重。anytls-go `169a009` 起首个连接最多等待 3 秒的首次探测，已发现解码端的通道在其暂时不可达时继续拦截、逐请求直发 origin。核对覆盖率可对比前端 `framed`+`plain` 与 Sub2API `/responses` 数，并确认 `passed_conns` 不增长。

解码连接存活：anytls-go `f239e43` 起，解码端同时接受 HTTP/1 与不加密 HTTP/2，并在 `/health` 带 `X-Edge-Dedup-H2c: 1`；前端看到后经 SOCKS5 出口改用一条 HTTP/2 连接，两端 15 秒无帧即 ping，链路静默约 30 秒内失败、改发原文。此前 HTTP/1 连接遇到只丢大包的出口 TCP 连接，会等内核重传超时（约 15 分钟）。旧前端与新解码端、新前端与旧解码端均保持 HTTP/1，升级时先换解码端。

升级前端用 `tools/dedup/upgrade.sh --router root@路由器`，加 `--server root@出口` 时同时调整解码端大小，再加 `--decoder` 时在同一步把出口的 `/usr/local/bin/anytls-dedup` 换成本次构建（失败回滚，并校验健康检查声明 HTTP/2）：默认只预检并在路由器 `/tmp` 暂存校验（随后删除），`--apply` 先重启解码端再并行切换前端，两边缓存只冷启动一次，不重启 sing-box 与 anytls-server，失败按备份回滚。

运维注意：`on`/`off` 会重启 Stargate。本次 02:09:55 重启时 Sub2API 在途请求遇到 `connection refused`/断流，4 个 OpenAI 账号被临时停调度 10 分钟，期间请求报无可用账号，手动恢复后正常。切换应避开高峰，或先在 Sub2API 暂停相关账号再切换。Chrome/Firefox 不使用系统信任库，在该主机上用浏览器访问这些域名会报证书错误。
