# AGENTS

本仓库默认使用中文协作。每轮修改前先读：

1. `docs/current.md`
2. `docs/reference/architecture.md`
3. 当前任务明确提到的文件

必要时再读：

- `docs/roadmap.md`
- `docs/reference/naming.md`
- `third_party/openwrt-passwall2`
- `third_party/sing-box`

## 项目边界

Stargate 是面向 OpenWrt 24 的 sing-box 管理平台。长期目标是吸收 PassWall2 在 OpenWrt 集成、DNS、透明代理、规则、服务编排和 UI 体验上的优秀经验，但保持更清晰的结构、更强的可验证性和更保守的默认行为。

第一阶段仍只管理 `sing-box` 一个核心，优先让 AnyTLS 节点以本机 SOCKS/HTTP 代理方式稳定跑通。

默认不要做这些事：

- 不默认启用透明代理。
- 不默认接管局域网 DNS、dnsmasq、DHCP 下发 DNS 或防火墙规则。
- 不管理 NetBird、PassWall2、OpenClash 等其他服务；长期最多只读展示或迁移导入。
- 不把未来计划写成当前已实现事实。
- 不为了目录规范创建空目录或拆出没有真实运行单元的 `apps/`。

## 第三方参考

`third_party/` 只放参考仓库：

- `third_party/openwrt-passwall2`：参考 PassWall2 的 OpenWrt 集成、功能边界和交互经验。
- `third_party/sing-box`：参考 sing-box `dev-next` 的配置、协议和上游实现。

硬性规则：

- Stargate 代码不允许 import、source、复制运行时路径或直接依赖 `third_party/`。
- `third_party/` 不参与构建、安装、发布和运行。
- 可以阅读和对照实现思路，但新代码必须在 Stargate 自己的结构中实现。
- 不要修改 third-party submodule 内容；需要更新时只更新 submodule 指针。

## 当前结构

- `scripts/stargate.sh`：当前唯一运行入口和 OpenWrt 服务安装/配置脚本。
- `examples/`：示例配置。
- `docs/current.md`：当前协作上下文和验收标准。
- `docs/reference/`：当前真实架构、命名、配置和运行边界。
- `docs/roadmap.md`：未来方向，不代表当前已实现。
- `third_party/`：只读参考，不是项目依赖。

## 验证入口

优先使用统一入口：

```sh
sh manage.sh check
```

当前本地检查重点是 shell 语法和文档链接。OpenWrt 设备上的功能验证仍以 `sing-box check`、`/etc/init.d/stargate` 和本机 SOCKS/HTTP 连通性测试为准。
