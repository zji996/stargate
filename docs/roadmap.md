# Roadmap

## 第一阶段：AnyTLS 本机代理

Status: In Progress

- 交互式导入 AnyTLS URI。
- 生成 `/etc/stargate/config.json`。
- 使用 `sing-box check` 校验配置。
- 安装 `/etc/init.d/stargate`。
- 默认只监听 `127.0.0.1` SOCKS/HTTP。
- 启动失败回滚上一份配置。

## 第二阶段：配置和诊断增强

Status: Not Implemented

- 增加非交互式配置写入入口，便于前端或 AI 调用。
- 增加 AnyTLS URI 解析样例测试。
- 增加诊断包导出，包含 sing-box 版本、服务状态、监听端口、最近日志、磁盘和内存情况。
- 更清晰地区分用户输入配置、生成后的 sing-box 配置和运行状态。

## 第三阶段：更多节点类型

Status: Not Implemented

- 添加 Vision URI 支持。
- 抽象节点解析结果，保持脚本、前端和 AI 使用同一份结构化数据。
- 保存前提供配置预览和 `sing-box check` 结果。
- 参考 `third_party/sing-box` 的上游配置模型，但不直接依赖参考仓库。

## 第四阶段：PassWall2 经验吸收

Status: In Progress

- 梳理 `third_party/openwrt-passwall2` 的 OpenWrt 包结构、服务编排、DNS、透明代理、规则管理和 UI 交互。
- 提炼适合 Stargate 的功能边界，不复制 PassWall2 的多核心和强耦合编排。
- 形成 Stargate 自己的配置模型、状态模型和操作 API。

## 第五阶段：前端或 TUI

Status: In Progress

- Overview：服务状态、sing-box 版本、监听地址、最后一次配置校验结果、最近日志。
- Node：节点导入、解析、连通性测试、保存前预览。
- DNS：展示 sing-box 内部 DNS 配置，系统级 DNS 接管默认关闭。
- Safety：配置备份、回滚、诊断包导出、其他代理服务只读状态。

## 第六阶段：显式网络接管能力

Status: Not Implemented

- 只代理路由器本机流量。
- 透明代理模式。
- 分流规则。
- nftables/iptables 预检、dry-run 和失败回滚。

这些能力必须默认关闭，不能在没有明确确认时停止、替换或接管其他网络服务。
