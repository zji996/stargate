# Stargate

一个面向 OpenWrt 24 的轻量 sing-box 管理项目，目标是替代复杂的一体化代理面板，先把 AnyTLS 节点稳定跑起来。

项目名为 `Stargate`，本地服务名和配置路径使用小写 `stargate`。

## 目标

- 只管理 `sing-box` 一个核心。
- 优先支持 AnyTLS URI。
- 配置生成后先执行 `sing-box check`，通过后才切换。
- 启动失败自动回滚上一份配置。
- 默认只开启本机 SOCKS/HTTP 入站，不接管全局网络。
- DNS 配置保持干净、可解释，避免一启动就改乱系统 DNS。
- 不管理 NetBird、PassWall2、OpenClash 等其他服务。
- 配置格式尽量结构化，便于 AI、脚本和前端共同读写。
- 前端以“少选项、可解释、可回滚”为核心，不做堆满开关的复杂面板。

## 非目标

- 第一阶段不做复杂分流规则。
- 第一阶段不默认启用透明代理。
- 不做订阅管理。
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

见 [docs/design.md](docs/design.md)。

## 当前背景

这个项目来自一次 OpenWrt 24 路由器排障：PassWall2 功能很全，但它同时编排 DNS、透明代理、分流、多个核心和 UI 状态。节点一旦启动导致网络异常，很难快速判断是节点协议、sing-box、DNS、iptables/nft 还是面板编排问题。

第一阶段故意只做本机 `127.0.0.1` SOCKS/HTTP 代理，不默认接管全局流量。这样可以先验证 AnyTLS 与 sing-box 在路由器上是否稳定，再逐步加透明代理、分流和前端。

## 路由器实测基线

- OpenWrt: 24.10.3
- 架构: `aarch64_cortex-a53`
- 内核: 6.12.58
- sing-box: 1.13.11
- AnyTLS 服务端形态: `SERVER_HOST:8443`
- AnyTLS URI 形态: `anytls://PASSWORD@SERVER_HOST:8443/?insecure=1`

注意：当前经验里，sing-box 对 AnyTLS 的最小配置校验可以通过；更大风险在复杂面板同时改 DNS、透明代理和防火墙规则时引入的不确定性。因此本项目先做小闭环。
