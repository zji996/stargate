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
- `luci-app-stargate/`：第一版 OpenWrt LuCI 管理前端包，负责 UCI 配置、页面、服务入口和配置生成后端。
- `manage.sh`：本地开发检查入口，只做命令路由。
- `examples/anytls.json`：结构化节点配置方向示例。
- `docs/current.md`：当前协作上下文。
- `docs/roadmap.md`：未来方向。
- `docs/reference/`：当前真实架构和命名边界。
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
- `start-transparent [redirect|tproxy] [port]`：设置为透明代理入站模式，生成 sing-box `redirect` 或 `tproxy` 入站并重启 Stargate，默认模式是 `redirect`，默认端口是 `12345`。

这两个动作都会先生成、校验并应用配置；服务重启失败时会恢复上一份备份配置。透明代理动作会尝试应用 Stargate 自己的防火墙规则；规则失败时会清理并回滚透明代理 UCI 状态。Stargate 不修改 dnsmasq 或 DHCP。

防火墙工具自动选择后端：优先使用 nftables，缺失时回退 iptables。当前规则只管理 Stargate 自己的链或表，便于状态检查和清理。

## 命名边界

`Stargate` 的含义是“稳定、可控、可观测的网络入口”。它不追求照搬复杂面板，而是以 sing-box 为核心，逐步形成完整一点的 OpenWrt 代理管理平台。

如果后续加入透明代理、分流、订阅，也应保持默认关闭，并且每个功能都有独立的检查和回滚。未来计划见 `docs/roadmap.md`。

## DNS 策略

默认 DNS 配置：

- `local`：系统本地解析器。
- `direct-dns`：默认使用阿里 DNS 的 TCP 预设 `tcp://223.5.5.5`。
- `remote-doh`：默认使用 Quad9 DoH 预设 `https://9.9.9.9/dns-query`，通过代理出站。
- `final`：默认 `direct-dns`。命中代理规则的域名仍会走 `remote-doh`，未命中的域名使用直连 DNS 兜底。

第一阶段的入站 SOCKS/HTTP 使用 sing-box 的 DNS 解析能力，不接管局域网 DNS。

DNS 重定向默认开启，但只在透明代理防火墙规则应用时实际接管受管设备的 TCP/UDP 53。后端会把 53 端口重定向到 sing-box 的本地 `dns-in` 入站，再通过 `hijack-dns` 动作进入 sing-box DNS 模块。

LuCI DNS 页面使用“预设下拉 + 自定义兜底”的形式。常用直连 DNS 和远端 DoH 预设会同时确定协议、服务器和 DoH path，避免只改服务器但忘记协议或路径导致 DNS 静默失效；选择 `Custom` 时才显示底层传输、服务器和 path。

## 规则策略

第一版规则来源使用 `Loyalsoldier/v2ray-rules-dat` 的 release 文本列表：

- `direct-list.txt` 转换为 `/usr/share/stargate/rules/direct.json`。
- `proxy-list.txt` 转换为 `/usr/share/stargate/rules/proxy.json`。
- 用户可在 Rules 页分别填写“用户直连域名”和“用户代理域名”，生成优先级高于上游列表的 route rule。

规则更新是显式动作，不在启动或生成配置时自动联网。Stargate 不内置离线 fallback 规则文件；当黑名单或白名单模式下本地规则文件缺失时，配置生成会失败并提示先更新规则。

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
