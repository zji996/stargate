# Stargate

一个面向 OpenWrt 24 的 sing-box 管理平台。长期目标是参考 PassWall2 的优秀经验，做出更清晰、可验证、可回滚的 OpenWrt 代理管理体验；当前先把 AnyTLS 节点稳定跑起来。

项目名为 `Stargate`，本地服务名和配置路径使用小写 `stargate`。

## 目标

- 以 `sing-box` 为唯一核心，先不做多核心选择。
- 优先支持 AnyTLS URI，后续扩展更多 sing-box 支持的节点类型。
- 配置生成后先执行 `sing-box check`，通过后才切换。
- 启动失败自动回滚上一份配置。
- 默认只开启本机 SOCKS/HTTP 入站，不接管全局网络。
- DNS 配置保持干净、可解释，避免一启动就改乱系统 DNS。
- 不管理 NetBird、PassWall2、OpenClash 等其他服务，长期最多只读展示或迁移导入。
- 配置格式尽量结构化，便于 AI、脚本和前端共同读写。
- 前端以“功能完整但默认保守、可解释、可回滚”为核心，吸收 PassWall2 的成熟经验，避免不可控的开关堆叠。

## 非目标

- 第一阶段不做复杂分流规则。
- 第一阶段不默认启用透明代理。
- 第一阶段不做订阅管理。
- 不做多核心选择。
- 不替换 OpenWrt 固件包管理。
- 不在没有明确确认时停止或接管其他网络服务。

## 快速安装

把仓库复制到 OpenWrt 后执行：

```sh
sh scripts/stargate.sh install
```

交互式配置 AnyTLS：

```sh
sh scripts/stargate.sh configure
```

查看状态：

```sh
sh scripts/stargate.sh status
```

默认监听：

- SOCKS: `127.0.0.1:10808`
- HTTP: `127.0.0.1:10809`

## LuCI 管理前端

第一版 LuCI 包位于 `luci-app-stargate/`，包含：

- UCI 配置：`/etc/config/stargate`
- procd 服务：`/etc/init.d/stargate`
- LuCI 页面：Overview、Node、DNS、Rules、Safety
- 兼容入口：现代 LuCI JS view + 旧式 Lua CBI fallback
- 后端入口：`/usr/share/stargate/stargate.sh`
- 基础规则：显式更新后生成 `/usr/share/stargate/rules/direct.srs`、`proxy.srs` 和 GeoIP `.srs`
- 多语言：源码默认英文，`po/zh-cn/stargate.po` 提供简体中文

Stargate 默认共用系统 `/usr/bin/sing-box`，不复制 PassWall2 的私有文件，也不另放一份 sing-box。它使用独立的 `/etc/stargate/config.json` 和 `/etc/init.d/stargate`。

在 OpenWrt SDK 中可作为 `luci-app-stargate` 包集成。设备上验证重点：

```sh
/usr/share/stargate/stargate.sh generate
/usr/share/stargate/stargate.sh check
/usr/share/stargate/stargate.sh apply
/etc/init.d/stargate restart
```

## AnyTLS URI 示例

```text
anytls://password@host:8443/?insecure=1
```

当前脚本会解析：

- host
- port
- password
- `insecure=1` / `insecure=true`
- `sni=example.com`

## 设计文档

建议阅读：

- [docs/current.md](docs/current.md)：当前目标、状态、边界和验收方式。
- [docs/reference/architecture.md](docs/reference/architecture.md)：当前架构和设计原则。
- [docs/reference/luci-platform.md](docs/reference/luci-platform.md)：LuCI 管理前端和第一版平台设计。
- [docs/reference/s20m-nftables-build.md](docs/reference/s20m-nftables-build.md)：S20M/S20L nftables 固件编译适配和刷后验证。
- [docs/roadmap.md](docs/roadmap.md)：后续阶段规划。

本地结构检查：

```sh
sh manage.sh check
```

## 第三方参考

`third_party/` 中的仓库只作为参考资料：

- `third_party/openwrt-passwall2`：参考 OpenWrt 集成、DNS、透明代理、规则和 UI 经验。
- `third_party/sing-box`：参考 sing-box `dev-next` 的上游配置和实现。

Stargate 的代码、构建、安装和运行都不能直接依赖 `third_party/`。

## 当前背景

这个项目来自一次 OpenWrt 24 路由器排障：PassWall2 功能很全，但它同时编排 DNS、透明代理、分流、多个核心和 UI 状态。节点一旦启动导致网络异常，很难快速判断是节点协议、sing-box、DNS、iptables/nft 还是面板编排问题。

第一阶段故意只做本机 `127.0.0.1` SOCKS/HTTP 代理，不默认接管全局流量。这样可以先验证 AnyTLS 与 sing-box 在路由器上是否稳定，再逐步加 DNS 管理、透明代理、分流、订阅导入和前端。

## 路由器实测基线

- OpenWrt: 24 系列
- 架构: aarch64 路由器
- sing-box: 1.13 系列
- AnyTLS 服务端形态: `SERVER_HOST:8443`
- AnyTLS URI 形态: `anytls://PASSWORD@SERVER_HOST:8443/?insecure=1`

注意：当前经验里，sing-box 对 AnyTLS 的最小配置校验可以通过；更大风险在复杂面板同时改 DNS、透明代理和防火墙规则时引入的不确定性。因此本项目先做小闭环。
