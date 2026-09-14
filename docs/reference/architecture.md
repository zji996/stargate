# 架构

## 为什么新项目

PassWall2 功能很完整，但它同时管理订阅、DNS、FakeDNS、透明代理、iptables/nft、分流、多个核心和 UI 状态。路由器内存有限时，问题很难隔离。

本项目长期目标是做一个更完整的 OpenWrt sing-box 管理平台，吸收 PassWall2 在 OpenWrt 集成、DNS、透明代理、规则、服务编排和 UI 体验上的优秀经验，同时保留更清晰的配置模型、更强的预检和回滚。

当前阶段先做更窄的目标：在 OpenWrt 24 上稳定管理 sing-box，让 AnyTLS 节点先以本机 SOCKS/HTTP 方式跑通。

## 产品原则

- 默认安全：不自动接管全局网络，不自动停用其他服务，不默认修改 DHCP 下发 DNS。
- 可验证：每次生成配置都必须先 `sing-box check`，再替换正式配置。
- 可回滚：启动失败时恢复上一份已知配置。
- 可解释：配置文件、脚本状态和前端展示的信息要能对应到真实 sing-box 配置。
- AI 友好：核心状态和配置使用稳定路径与结构化 JSON，便于 AI 辅助生成、检查和修复。
- 阶段推进：第一阶段只做 AnyTLS、SOCKS、HTTP、内部 DNS、状态检查和回滚；后续再扩展 DNS 接管、透明代理、分流、订阅和前端。
- 经验复用：可以参考 PassWall2 和 sing-box 上游实现，但不能让 Stargate 的运行时依赖参考仓库。

## 第一阶段

- 生成 `/etc/stargate/config.json`。
- 安装 `/etc/init.d/stargate`。
- 使用 `/usr/bin/sing-box check -c config` 做配置校验。
- 新配置先写到 `.next`，校验通过后再替换正式配置。
- 替换前备份上一份配置到 `/etc/stargate/config.json.bak`。
- 启动失败时回滚上一份配置。
- DNS 优先写 sing-box 内部 DNS；透明代理场景可通过 Stargate 自己的防火墙规则把受管设备 DNS 重定向到 sing-box。
- LuCI 版后端提供显式 `rollback` 动作，会先用 `sing-box check` 校验备份配置，再恢复到正式配置；如果服务正在运行，会用恢复后的配置重启。

## 仓库结构

当前项目没有多个独立运行单元，不拆 `apps/` 或 `packages/`。

- `scripts/stargate.sh`：当前唯一业务脚本，负责安装服务、解析 AnyTLS URI、生成配置、校验、启动、停止、状态查看和卸载。
- `luci-app-stargate/`：第一版 OpenWrt LuCI 管理前端包，负责 UCI 配置、页面、服务入口和配置生成后端。LuCI 后端统一入口是 `root/usr/share/stargate/stargate.sh`，具体实现按 common、nodes、rules、config、firewall、maintenance 拆到 `root/usr/share/stargate/lib/*.sh`。
- `manage.sh`：本地开发检查入口，只做命令路由。
- `examples/anytls.json`：结构化节点配置方向示例。
- `docs/current.md`：当前协作上下文。
- `docs/roadmap.md`：未来方向。
- `docs/reference/`：当前真实架构、LuCI 平台、实机部署经验和命名边界。
- `third_party/openwrt-passwall2`：PassWall2 参考仓库，只读参考。
- `third_party/sing-box`：sing-box `dev-next` 参考仓库，只读参考。

`third_party/` 不参与构建、安装、发布和运行，Stargate 代码不允许直接引用其中内容。

## 运行路径

- 配置目录：`/etc/stargate`
- 运行配置：`/etc/stargate/config.json`
- 下一份待校验配置：`/etc/stargate/config.json.next`
- 上一份备份配置：`/etc/stargate/config.json.bak`
- 回滚前保留的失败配置：`/etc/stargate/config.json.rollback_from`
- 本地监听环境文件：`/etc/stargate/env`
- init 服务：`/etc/init.d/stargate`
- 默认 sing-box：`/usr/bin/sing-box`

`SINGBOX_BIN` 可以覆盖本地 sing-box 路径，但 init 脚本当前仍使用 `/usr/bin/sing-box`。

## 配置切换流程

当前交互式配置流程：

1. 读取 AnyTLS URI。
2. 读取 SOCKS/HTTP 监听地址，默认使用 `127.0.0.1:10808` 和 `127.0.0.1:10809`。
3. 生成 `/etc/stargate/config.json.next`。
4. 执行 `sing-box check -c /etc/stargate/config.json.next`。
5. 如果已有正式配置，复制为 `/etc/stargate/config.json.bak`。
6. 将 `.next` 替换为正式配置。
7. 启动失败时尝试复制 `.bak` 回正式配置并重启。

LuCI 版后端还提供两个显式启动动作：

- `start`：设置为本机代理模式，只生成 SOCKS/HTTP 入站并重启 Stargate。
- `start-transparent redirect [port]`：设置为透明代理入站模式，生成 sing-box `redirect` 入站并重启 Stargate，默认端口是 `12345`。当前防火墙后端不支持 TProxy，运行态入口会提前拒绝该模式。
- `apply-runtime`：按当前 UCI 期望同步运行态。`global.enabled=0` 会停止服务、禁用 init 自启并清理 Stargate 防火墙规则；`global.enabled=1` 会根据 `inbound.transparent_proxy` 选择本机代理或透明代理启动路径。

这两个动作都会先生成、校验并应用配置；服务重启失败时会恢复上一份备份配置。透明代理动作会尝试应用 Stargate 自己的防火墙规则；规则失败时会清理并回滚透明代理 UCI 状态。Stargate 不修改 dnsmasq 或 DHCP。

LuCI Overview 的保存动作和 init 脚本 reload 都走 `apply-runtime`，init 启动时也会先读取 `global.enabled`。这保证页面勾选状态、服务运行状态和开机自启状态一致，避免只保存 UCI 但运行中的 sing-box 或透明代理规则没有被撤销。

Advanced 页的“转发配置”负责防火墙规则应用和清理。后端自动选择：优先使用 nftables，缺失时回退 iptables。当前规则只管理 Stargate 自己的链或表，便于状态检查和清理。

### NetBird 接管边界

透明代理启用时，`inbound.netbird_proxy` 默认 `1`，将 `inbound.netbird_interface`（默认 `wt0`）与 LAN 一起作为受管入口。关闭该选项只撤销 NetBird 接管，保留 LAN 透明代理。接口名独立于 LAN 配置，避免为了接管 VPN 而修改 `network.lan.device`。

NetBird 入站访问其他私有 IPv4/IPv6 目标时先绕过，包括其他内网 DNS；访问本路由器的 DNS、公网 DNS 和 IPv4 TCP 时进入现有 DNS/代理分流。受管接口的公网 IPv6 被 guard 阻断，UDP/443 按 QUIC 开关处理，其他 UDP 不代理。NetBird ACL 和系统防火墙仍然负责入站授权；Stargate 不修改它们，部署时必须单独核对重定向后 INPUT 路径是否获准。

这只提供数据面接管，不发布 NetBird exit node、不替客户端选择出口，也不改变 NetBird Auto Apply。当前出口设计与未完成验收见 [NetBird 出口设计](netbird-exit-node.md)。nft 后端将校验通过的删除旧表和新建表合并为一个事务，校验失败时保留原表；iptables 后端目前仍按既有链更新流程执行。

### LuCI 交互边界

CBI 页面通过 `luci.model.stargate.common` 引入共用模板和 `stargate-cbi.js`，集中处理 POST 动作、文件上传反馈、移动端弹窗和键盘焦点。修改配置后由 LuCI 正常提交并触发 procd reload，页面不在提交前抢先应用旧配置。上传控件使用独立 FormData 请求，避免在 LuCI 主表单内嵌套 form。

## 命名边界

`Stargate` 的含义是“稳定、可控、可观测的网络入口”。它不追求照搬复杂面板，而是以 sing-box 为核心，逐步形成完整一点的 OpenWrt 代理管理平台。

如果后续加入透明代理、分流、订阅，也应保持默认关闭，并且每个功能都有独立的检查和回滚。未来计划见 `docs/roadmap.md`。

## DNS 策略

- `lan-dns`：通过 TCP 显式访问 `127.0.0.1` 上的 dnsmasq，读取其配置端口（默认 53）。本地域名、单标签主机名、私网反向解析交给它，避免系统 resolver 被 NetBird 接管后绕回不确定的上游。
- `direct-dns`：默认阿里 TCP DNS；用于直连域名及远端 DoH 自举。
- `remote-doh`：默认 `https://dns.google/dns-query`，通过 AnyTLS 出站，显式用 `direct-dns` 自举。
- 解析优先级：本地域名 → 用户直连域名 → 用户代理域名 → 基础 proxy → 基础 direct → 模式兜底。基础 direct/proxy 冲突时 proxy 优先。
- DNS 兜底跟随模式：黑名单/仅直连为 `direct-dns`，白名单/全局代理为 `remote-doh`。旧 UCI `dns.final` 保留兼容读取，但不再决定运行配置；LuCI 显示自动策略。

只启用本机 SOCKS/HTTP 时不接管客户端 DNS。透明代理且 DNS 重定向开启时，接管受管设备的 IPv4/IPv6 TCP/UDP 53。IPv4 用 REDIRECT；IPv6 使用绑定具体 LAN 地址的 `dns6-in`，并 DNAT 到同一地址，优先稳定 ULA。不能使用通配 IPv6 UDP 监听加 REDIRECT：多地址 LAN 上可能产生不同回复源地址，无法完成反向 NAT。LAN 接口变化由 procd trigger 重新加载配置；有 IPv6 却尚无可绑定 LAN 地址时预检失败，等待接口就绪。

Stargate 不修改 dnsmasq 上游、DHCP 或 RA。本地域名固定交回 dnsmasq；部署前仍需保证其监听本机 TCP DNS，且没有自定义上游指回 Stargate 形成环路。`.lan`、配置的 dnsmasq domain、`home.arpa`、单标签主机名及常见私网反向区域走本地解析。

## 规则策略

规则来自 Loyalsoldier clash-rules 和 MetaCubeX GeoIP `.srs`：direct/private/cncidr/lancidr 合成 `direct.json/.srs`；proxy/gfw/tld-not-cn/telegramcidr 合成 `proxy.json/.srs`；另加载 CN、Google、Facebook、Twitter、Telegram GeoIP 数据。更新为显式操作，先在临时目录下载和编译完整文件，再安装并同步运行态；不从 `third_party/` 加载，不提供离线伪造数据。

黑名单/白名单的路由顺序：

1. DNS 劫持、sniff、QUIC 拒绝及私网直连；本地域名先用 `lan-dns` 解析再直连。
2. 用户直连域名、用户直连 IP、用户代理域名、用户代理 IP。
3. 内置代理 CIDR 补充、基础 proxy、GeoIP proxy、基础 direct、GeoIP direct。
4. 尚未命中时按模式 DNS 兜底解析一次，再检查私网、用户 IP 与基础/GeoIP IP 规则。内置 CIDR 补充也参与解析后的复判。
5. 黑名单未命中直连，白名单未命中走 AnyTLS。全局代理/仅直连跳过用户覆盖与基础规则，仅保留本地/私网及协议处理规则。

IP 规则只能检查当时已知的目标 IP；DNS 使用域名策略，不能提前评估尚未解析出的 IP。Rules 测试明确区分域名策略和实际连接：域名输入不验证目标 IP、sniff 和连通性；没有域名命中时返回“需要解析”，不假装已经完成 GeoIP 复判。

防火墙 `direct4` / `STARGATE_DIRECT4` 只保留私网和保留地址。公网基础直连 CIDR、用户直连 CIDR 均由 sing-box 判定，以免提前绕过用户域名和代理规则。代价是国内 TCP 也会进入核心后直连，需要观察负载；内网访问仍走普通路由。

## 透明代理防火墙

nftables 表 `inet stargate` 先完整预检，再在一个事务内替换：

- NAT PREROUTING `-110`：先处理 NetBird 其他私网目标绕过，再做 IPv4/IPv6 DNS、私网/保留地址绕过，最后接管公网 IPv4 TCP。
- filter PREROUTING `-10`：DNS 已经 DNAT，保留回复流量、本机 INPUT、NetBird 私网与本地 IPv6；拒绝受管公网 IPv6，按开关拒绝 UDP/443。

guard 不放在 FORWARD，避免 NetBird 自动插入的放行规则抢先结束检查。也不能将 filter guard 插在多个 NAT 优先级之间：S20M 实测这时可能先看到未 DNAT 的公网 IPv6 DNS 并误拒绝，所以 guard 放在所有常规 DNAT hook 之后的 -10。S20M 的内核/nft 已验证 PREROUTING reject；其他固件必须通过本机 nft 预检后应用，不支持时保留旧表。Stargate 不增加其他服务的 INPUT/FORWARD 授权。

当前只透明代理 IPv4 TCP，普通 IPv4 UDP 保持系统路径，公网 IPv6 被拒绝。iptables fallback 提供 IPv4 redirect、IPv6 DNS DNAT 和既有 FORWARD guard；其 NetBird guard 兼容性尚未实机验收。

## 路由器经验

当前排障得到的经验：

- 不建议在 OpenWrt 上做全量 `opkg upgrade`，容易碰到内核、nftables、firewall4 依赖不匹配。
- sing-box AnyTLS 最小配置可以通过 `sing-box check`。
- PassWall2 这类全功能面板的问题不一定在 sing-box 协议实现本身，更可能出现在 DNS、透明代理、分流规则和服务编排叠加处。
- NetBird 等旁路服务不应由本项目管理，最多只读展示状态。
- `/tmp` 空间和内存占用需要在诊断里显示，避免更新包或日志撑爆路由器。

## 测试策略

本机测试优先级：

- shell 语法检查。
- AnyTLS URI 解析样例测试。
- 生成 JSON 后用 `sing-box check` 校验。
- 在 OpenWrt 上只启动 `127.0.0.1` SOCKS/HTTP 入站，使用 `curl --socks5-hostname 127.0.0.1:10808` 验证，不接管全局网络。
- 对透明代理和 DNS 接管功能，必须先做 dry-run 和回滚测试，再允许进入默认菜单。
