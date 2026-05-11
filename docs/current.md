# 当前状态

## 当前目标

保持清晰的项目结构，让下一轮人类或 AI 能快速理解 Stargate 的目标、边界、当前实现和验证方式。

## 项目定位

Stargate 是面向 OpenWrt 24 的 sing-box 管理平台。长期目标是参考 PassWall2 的优秀经验，覆盖节点管理、DNS、透明代理、分流、诊断、备份回滚和前端控制台，但默认行为更保守、状态更可解释、配置切换更可验证。

第一阶段只解决一个窄问题：让 AnyTLS 节点通过 `sing-box` 在路由器上稳定跑起来，并默认只提供本机 `127.0.0.1` SOCKS/HTTP 入站。

## 已确认方向

- 只管理 `sing-box` 一个核心。
- 第一阶段优先支持 AnyTLS URI。
- 配置生成后必须先执行 `sing-box check`，通过后再切换。
- 新配置先写入 `.next`，正式替换前备份上一份配置。
- 启动失败时尝试回滚上一份配置。
- DNS 优先写 sing-box 内部 DNS；DNS 重定向默认开启，但只有透明代理防火墙规则应用时才接管受管设备的 53 端口。
- 默认不接管全局网络，不启用透明代理。
- 配置和状态尽量结构化，便于脚本、前端和 AI 共同读写。
- `third_party/` 只放参考仓库，Stargate 代码不能引用或依赖其中内容。

## 当前实现

- `scripts/stargate.sh` 提供 `install`、`configure`、`status`、`start`、`stop`、`restart`、`check`、`uninstall`。
- `luci-app-stargate/` 提供第一版 OpenWrt LuCI 管理前端包，包括 UCI 配置、procd 服务、LuCI JS 页面、Lua CBI fallback 页面和配置生成后端。
- LuCI 页面源码默认英文，`po/zh-cn/stargate.po` 提供简体中文翻译，跟随 OpenWrt LuCI 语言切换。
- `configure` 交互式读取 AnyTLS URI，生成 `/etc/stargate/config.json`。
- `/etc/init.d/stargate` 使用 procd 启动 `/usr/bin/sing-box run -c /etc/stargate/config.json`。
- `third_party/openwrt-passwall2` 和 `third_party/sing-box` 已作为 submodule 添加，仅供参考。
- 默认监听：
  - SOCKS: `127.0.0.1:10808`
  - HTTP: `127.0.0.1:10809`
- `examples/anytls.json` 是结构化输入方向示例，不是当前脚本直接读取的完整 sing-box 配置。
- LuCI 第一版设计见 `docs/reference/luci-platform.md`。
- 2026-05-10 测试路由器上系统已有 `/usr/bin/sing-box`，PassWall2 也配置使用该路径。Stargate 应共用系统 sing-box 二进制，但保持独立配置和服务。
- 2026-05-10 在测试路由器上做过隔离测试：`sing-box check` 通过，短时运行只监听临时本机端口，没有接管透明代理、DNS 或防火墙。
- 2026-05-11 在路由器上部署 LuCI 时发现该固件不支持 Lua controller 的 `view()` 入口，已改用 `cbi()` + `luasrc/model/cbi/stargate/client/*.lua`。服务菜单已正常出现。
- Overview 状态面板参考 PassWall2 的点击式检测体验；未运行时检测会明确显示 Stargate 未运行。Stargate 运行时连接检测走本地 HTTP 入站以体现代理后的可达状态，只有透明代理已开启且转发规则实际 Active 时才标记为透明代理路径。检测结果返回 HTTP 状态、延迟、出口 dev/src 和检测路径。
- Overview 保留状态、连接检测和勾选式启用入口：先勾选本机代理，之后才允许勾选透明代理，并通过 LuCI 右下角保存应用提交。透明代理默认仍关闭，不会在未显式勾选时接管网络。
- 日志独立为 Logs 页；Maintenance（维护）页分为 `sing-box 设置` 和 `备份还原` 两块，前者只保留 sing-box 执行文件路径和未来组件升级占位，后者参考 PassWall2 的备份还原体验，提供下载备份、恢复备份、恢复默认配置和保留生成配置回滚。
- Logs 页默认过滤 sing-box 直连出站超时噪声并移除 ANSI 颜色码，同时保留原始日志视图和清理系统日志入口。
- 未配置当前节点时，Overview 会显示阻塞提示；init 脚本启动前会再次检查当前节点，防止绕过 LuCI 启动。
- Node 页开始提供轻量节点列表，支持手动添加 AnyTLS、通过 `anytls://` 链接添加、编辑节点、使用节点和删除节点。新增和链接添加入口位于节点列表上方，节点编辑和“使用此节点”跟随列表行。第一版不做订阅和多协议导入。
- DNS 页使用预设下拉加自定义兜底：默认直连 DNS 为阿里 DNS TCP，远端 DNS 为 Quad9 DoH，`final` 默认为 `direct-dns`，代理规则命中域名仍通过 DNS 规则走 `remote-doh`。DNS 重定向默认开启，透明代理防火墙规则应用后会把受管设备的 53 端口导入 sing-box DNS。
- Advanced 页提供“转发配置”，会自动优先使用 nftables，缺失时回退 iptables，并提供能力检测、应用透明代理转发和清理 Stargate 转发；工具只管理 Stargate 自己的规则，不修改 PassWall2/OpenClash 规则。某些固件可能只有 iptables 或缺少 `kmod-nft-*`，此时会自动回退。
- Rules 页改为 Loyalsoldier 基础规则体系，不再内置离线 fallback。用户需要显式更新规则，后端将 `direct-list.txt` 和 `proxy-list.txt` 转换为 sing-box `source` rule-set；页面只暴露黑名单/白名单模式和用户直连/代理域名，默认出站与代理出站由模式自动决定。
- Rules 页提供测试策略入口，可输入域名或 IP，按当前模式、用户规则、基础规则集和默认出站判断最终走 Proxy 还是 Direct，并显示命中原因。

## 当前边界

- 不移动或删除 `scripts/stargate.sh`，它仍是当前稳定命令实现。
- 不把项目强行拆成 monorepo；当前没有多个独立运行单元。
- 不新增空的 `apps/`、`packages/` 或复杂工程目录。
- 不从 `third_party/` import、source、复制运行时路径或建立构建依赖。
- 前端、透明代理、订阅、多协议导入都属于未来阶段，但方向上属于 Stargate 长期目标。

## 验收标准

本阶段完成时应满足：

- 文档入口清晰，下一轮先读 `AGENTS.md`、`docs/current.md`、`docs/reference/architecture.md` 即可接上。
- README 指向当前真实结构和统一验证入口。
- 未来方向放在 `docs/roadmap.md`，当前事实放在 `docs/reference/`。
- 本地检查命令可执行。

## 验证命令

```sh
sh manage.sh check
```

OpenWrt 设备上的功能验证：

```sh
sh scripts/stargate.sh install
sh scripts/stargate.sh configure
sh scripts/stargate.sh check
sh scripts/stargate.sh start
sh scripts/stargate.sh status
```

连通性测试示例：

```sh
curl --socks5-hostname 127.0.0.1:10808 https://www.cloudflare.com/cdn-cgi/trace
```

## 下一步

下一步优先根据实际页面体验调整 CBI 页面布局，再验证 UCI 保存、配置生成、`sing-box check` 和服务启动。任何会改变系统网络行为的能力都必须默认关闭，并有预检和回滚。
