# 设计

## 为什么新项目

PassWall2 功能很完整，但它同时管理订阅、DNS、FakeDNS、透明代理、iptables/nft、分流、多个核心和 UI 状态。路由器内存有限时，问题很难隔离。

本项目先做更窄的目标：在 OpenWrt 24 上稳定管理 sing-box，让 AnyTLS 节点先以本机 SOCKS/HTTP 方式跑通。

## 产品原则

- 默认安全：不自动接管全局网络，不自动停用其他服务，不默认修改 DHCP 下发 DNS。
- 可验证：每次生成配置都必须先 `sing-box check`，再替换正式配置。
- 可回滚：启动失败时恢复上一份已知配置。
- 可解释：配置文件、脚本状态和前端展示的信息要能对应到真实 sing-box 配置。
- AI 友好：核心状态和配置使用稳定路径与结构化 JSON，便于 AI 辅助生成、检查和修复。
- 少即是稳：第一阶段只做 AnyTLS、SOCKS、HTTP、内部 DNS、状态检查和回滚。

## 第一阶段

- 生成 `/etc/stargate/config.json`。
- 安装 `/etc/init.d/stargate`。
- 使用 `/usr/bin/sing-box check -c config` 做配置校验。
- 新配置先写到 `.next`，校验通过后再替换正式配置。
- 替换前备份上一份配置到 `/etc/stargate/config.json.bak`。
- 启动失败时回滚上一份配置。
- DNS 只写 sing-box 内部 DNS，不修改 dnsmasq、不改 DHCP 下发 DNS。

## 命名边界

`Stargate` 的含义是“稳定、可控、可观测的网络入口”。它不是完整替代所有 OpenWrt 网络插件的面板，而是先把一个 sing-box 节点稳定运行这件事做好。

如果后续加入透明代理、分流、订阅，也应保持默认关闭，并且每个功能都有独立的检查和回滚。

## DNS 策略

默认 DNS 配置：

- `local`：系统本地解析器。
- `direct`：`udp://223.5.5.5`。
- `remote`：`tls://1.1.1.1`，通过代理出站。

第一阶段的入站 SOCKS/HTTP 使用 sing-box 的 DNS 解析能力，不接管局域网 DNS。

## 后续阶段

- 添加 Vision URI 支持。
- 添加只代理路由器本机流量的模式。
- 添加透明代理模式，但必须做成显式开启。
- 添加 nftables/iptables 前检查和回滚。
- 添加 Web UI 或更友好的 TUI。

## 前端方向

前端应避免复刻复杂插件的“所有能力都摆上来”模式。推荐分成四个稳定页面：

- Overview：服务状态、sing-box 版本、监听地址、最后一次配置校验结果、最近日志。
- Node：节点导入、AnyTLS/Vision 解析、连通性测试、保存前预览。
- DNS：本机代理 DNS、远端代理 DNS、直连 DNS，所有系统级接管默认关闭。
- Safety：配置备份、回滚、诊断包导出、只读展示其他代理服务状态。

每个会改变系统网络行为的操作都需要预检、确认和失败回滚。UI 不直接拼 shell 命令，而是写结构化配置，再调用固定脚本动作。

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
