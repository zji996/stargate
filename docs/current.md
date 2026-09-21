# 当前状态

## 当前目标

多出口分流与独立代理入站端口已在仓库实现并通过本地与容器验证，待实机部署验收；IPv6 DNS 与分流优先级保持既有保障。下一步按出口设计发布仅供测试客户端选择的 NetBird exit node，并完成远端验收。保持其他路由器和组网服务边界。

## 2026-09-21 更新

- 实现多出口分流与节点独立入站代理端口（Dedicated Port），尚未实机部署验收：
  - 核心分流架构遵循“直连规则全局共用，代理规则按入站映射到对应出口”。
  - 节点项（`node_item`）支持配置 `enable_port`、`socks_port`、`http_port`、`listen`。添加/编辑节点时即校验监听地址格式，并拒绝与主 SOCKS/HTTP、透明代理、DNS 劫持端口或其他节点独立端口冲突；生成配置时再次校验。
  - sing-box `inbounds` 为启用独立端口的节点创建 `in-socks-<id>` / `in-http-<id>`；与当前节点（server/port/password 相同）的节点复用 `anytls-out`，其余节点生成 `out-node-<id>` AnyTLS 出站。匿名 UCI section 会被跳过。
  - 分流规则在保持全局私网、局域网和国内直连的前提下，将辅助端口进来的 proxy 规则、海外 GeoIP 规则以及二次 DNS 解析判定结果，精确导向对应的辅助节点出口；主入站和复用主节点的入站流向 `anytls-out`。`global_proxy` 下辅助端口全部走对应节点，`direct` 下仍开端口但全部直连。
  - LuCI CBI 节点弹窗与 JS view 支持独立端口配置，`status` JSON 增加 `aux_nodes`，概览显示已开放的独立端口；监听 `0.0.0.0` 会在表单提示保持防火墙 WAN 入站关闭，Stargate 不额外添加防火墙规则。
  - `tests/routing.sh` / `tests/routing.py` 覆盖四种模式下的多入站判定、主节点别名、匿名 section、端口冲突和监听地址负向用例。`manage.sh check` 在缺少 lua 时可回退到已存在的 `nickblah/lua:5.1` Docker 镜像做 Lua 语法检查。
  - 本地验证：`manage.sh check` 通过；四种模式生成配置经 sing-box v1.12.4 `check` 通过；在 `openwrt/rootfs` 容器中用真实 `uci` 验证了节点增改、冲突拒绝、`node-list`、`generate` 与 `status`。实机 S20M 尚未部署本次改动。

## 2026-09-14 更新

- 用户授权修复 IPv6 DNS、统一分流优先级，同步仓库/设备，并设计通过 NetBird exit node 使用 Stargate。已部署 `192.168.6.1`，没有修改 `192.168.8.1` 的服务或路由，没有发布新的 NetBird exit route。
- IPv4/IPv6 TCP/UDP 53 均接管。IPv6 DNS 必须绑定具体 LAN 地址（优先 ULA），并 DNAT 到同一地址；多地址 LAN 上通配 `::` + REDIRECT 会选错 UDP 回复源地址。LAN 接口变化有 procd reload trigger，缺可绑定地址时预检失败。
- `.lan`、dnsmasq 配置域、单标签主机名和私网反向解析显式交回 `127.0.0.1` 的 dnsmasq TCP 端口，避免经过 NetBird 管理的系统 resolver。
- DNS 采用用户直连 → 用户代理 → 基础 proxy → 基础 direct；模式自动决定兜底。路由用户域名优先于基础 IP 补充，解析后重查用户 IP 和补充 CIDR。全局代理/仅直连跳过隐藏的旧覆盖和基础规则。旧 UCI `dns.final` 不再决定结果，LuCI 已改为显示自动策略。
- 公网 CIDR 不再加入防火墙 direct4 绕过集合；国内公网 TCP 也进入 sing-box 后分流。Rules 域名测试标明检查范围，未知域名需要解析后才能判定 IP 策略。
- 设备 NetBird 为 0.72.4，会自动向其他 INPUT/FORWARD 链插入接受规则。nft guard 已改到 DNS NAT 之后的 PREROUTING -10，避免被自动放行覆盖。NetBird 到其他私网目标仍保持原路径，到本路由器的 DNS 也按新策略接管。
- 验证：`sh manage.sh check`；四种模式实机配置校验；nft dry-run；正式 DNS 32 组查询通过，覆盖 IPv4、ULA、GUA、手填公网 IPv6 DNS 及 TCP/UDP；回归确认 UDP 反向 NAT。LAN 无应用代理：百度/Facebook/GitHub 200，Google/gstatic 204，ChatGPT TLS 成功但站点返回 403；不能据此宣称 ChatGPT 业务访问已通过。
- 本机 Windows DNS 缓存已清理。LAN UDP/443 和公网 IPv6 TCP 探测均立即拒绝；原 NetBird 私网对端 ICMP 正常。隔离验证进程和临时 nft 表已移除。
- 最终部署前备份：`/root/stargate-fix-20260914-114242/files.tar.gz`、`stargate.nft`、`firewall.nft`；目录内 `rollback.sh` 可恢复本次文件和 Stargate 表。已实际执行过回滚。最终部署已通过首轮回归并取消自动回滚计时。
- [NetBird 出口设计](reference/netbird-exit-node.md) 区分已部署数据面、尚未执行的控制台配置和远端验收。普通 UDP 仍不经代理，公网 IPv6 仍拒绝；iptables 新增 IPv6 DNS 路径尚未实机验收，当前出口方案基于 S20M nft。

## 2026-09-07 更新（历史记录）

2026-09-08 概览精简：主页只保留运行状态、版本、连接检测和服务/流量开关，不显示节点地址或节点名称；端口与 NetBird 接口移至高级页。共用独立概览样式，重置主题浮动字段布局，移除冗余说明并修正深色主题操作栏背景。已部署 S20M，Playwright 验证深浅色主题下 390/1440/2048 像素布局、控件无重叠、连接检测及主页 HTML 无节点 IP。

- 用户授权透明代理启用时默认接管 NetBird 接口 `wt0`；`inbound.netbird_proxy=0` 可关闭，`inbound.netbird_interface` 可配置接口名。透明代理总开关仍默认关闭，不修改 NetBird 服务、控制面、出口选择或发布路由。
- IPv4 TCP、公网 DNS、QUIC 阻断及公网 IPv6 guard 覆盖 LAN 和受管 NetBird 接口；NetBird 到私有网段的访问（包含内网 DNS）保持原路径。当前仍不代理一般 UDP 或公网 IPv6。
- nftables 规则先完整校验，再以同一事务替换 Stargate 表。后端状态显示受管接口。
- LuCI CBI 共用提交动作、上传反馈及弹窗层级实现。维护页移除嵌套表单，修改动作使用带会话 token 的 POST，节点删除/回滚/重置有确认；移动端文件控件与节点弹窗已修正。
- 概览移除提前执行的运行态提交钩子，使用 LuCI 正常提交和既有 procd reload trigger；JS 概览也取消重复应用。页面移除未支持的 TProxy 选项，后端在改动配置前拒绝该透明转发模式。
- 已部署 `192.168.6.1`，未修改 `192.168.8.1`。部署前备份为 `/root/stargate-upgrade-20260907/files.tar.gz` 和 `firewall.nft`。
- 验证：`sh manage.sh check`；实机 sing-box 校验；Google 本机代理和 LAN 客户端显式 IPv4 无应用代理请求均 HTTP 204；NetBird 对端 ICMP 正常；Playwright 桌面/手机六页面截图、弹窗遮挡/退出、空上传提示、临时节点添加删除、NetBird 开关保存后的规则撤销与恢复均通过。
- 验证边界：当前控制面提供的 exit node 仍是 GL-MT6000，S20M 未新增出口路由；尚未使用出差客户端完成选择 S20M 出口后的端到端实测。不能把本机 HTTP 检测等同于 NetBird 出口验证。

## 项目定位

Stargate 是面向 OpenWrt 24 的 sing-box 管理平台。长期目标是参考 PassWall2 的优秀经验，覆盖节点管理、DNS、透明代理、分流、诊断、备份回滚和前端控制台，但默认行为更保守、状态更可解释、配置切换更可验证。

第一阶段只解决一个窄问题：让 AnyTLS 节点通过 `sing-box` 在路由器上稳定跑起来，并默认只提供本机 `127.0.0.1` SOCKS/HTTP 入站。

## 已确认方向

- 只管理 `sing-box` 一个核心。
- 第一阶段优先支持 AnyTLS URI。
- 配置生成后必须先执行 `sing-box check`，通过后再切换。
- 新配置先写入 `.next`，正式替换前备份上一份配置。
- 生成结果与当前配置相同时不重复替换或覆盖备份；脚本已经准备好配置后重启 init 时不会再次生成，避免把上一份可回滚配置覆盖成当前配置。
- 启动失败时尝试回滚上一份配置。
- DNS 优先写 sing-box 内部 DNS；DNS 重定向默认开启，但只有透明代理防火墙规则应用时才接管受管设备的 53 端口。
- 默认不接管全局网络，不启用透明代理。
- 配置和状态尽量结构化，便于脚本、前端和 AI 共同读写。
- `third_party/` 只放参考仓库，Stargate 代码不能引用或依赖其中内容。

## 当前实现

- `scripts/stargate.sh` 提供 `install`、`configure`、`status`、`start`、`stop`、`restart`、`check`、`uninstall`。
- `luci-app-stargate/` 提供第一版 OpenWrt LuCI 管理前端包，包括 UCI 配置、procd 服务、LuCI JS 页面、Lua CBI fallback 页面和配置生成后端。LuCI 后端以 `/usr/share/stargate/stargate.sh` 为统一入口，具体能力拆在 `/usr/share/stargate/lib/*.sh`。
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
- Overview 状态面板参考 PassWall2 的点击式检测体验；未运行时检测会明确显示 Stargate 未运行。Stargate 运行时连接检测走本地 HTTP 入站，只验证节点和本机代理可达性，不再把“防火墙表存在”误标为已经走过透明代理。透明转发是否真正承载 LAN 流量应结合 firewall status 中的 DNS、transparent 和 direct-bypass 规则计数判断。
- Overview 保留状态、连接检测和勾选式启用入口：先勾选本机代理，之后才允许勾选透明代理，并通过 LuCI 右下角保存应用提交。透明代理默认仍关闭，不会在未显式勾选时接管网络。
- Overview 保存后会调用统一的运行态同步入口：`global.enabled=0` 时停止 Stargate、禁用 init 自启并清理 Stargate 防火墙规则；`global.enabled=1` 时按当前本机/透明代理配置生成配置、校验并启动。init 脚本本身也会尊重 `global.enabled`，避免重启后绕过 LuCI 重新拉起代理。
- 日志独立为 Logs 页；Maintenance（维护）页分为 `sing-box 设置` 和 `备份还原` 两块。备份包含 UCI、生成配置、direct/proxy 源文件与编译规则以及全部 GeoIP `.srs`；恢复前校验 manifest、归档路径、文件类型和 UCI 语法，恢复后通过 `apply-runtime` 同步服务与防火墙。sing-box 升级使用压缩回滚副本，写入前检查 overlay 空间，新文件在同目录完成版本和配置检查后原子替换；运行中替换失败时自动恢复旧二进制。
- Logs 页默认过滤 sing-box 直连出站超时噪声并移除 ANSI 颜色码，同时保留原始日志视图和清理系统日志入口。
- 未配置当前节点时，Overview 会显示阻塞提示；init 脚本启动前会再次检查当前节点，防止绕过 LuCI 启动。
- Node 页开始提供轻量节点列表，支持手动添加 AnyTLS、通过 `anytls://` 链接添加、编辑节点、使用节点和删除节点。新增和链接添加入口位于节点列表上方，节点编辑和“使用此节点”跟随列表行。第一版不做订阅和多协议导入。
- 节点和入站端口在后端统一校验为 `1..65535`；AnyTLS URI 的密码、SNI 和标签按 URI 百分号编码解码，字面量 `+` 不会被错误转换为空格。
- DNS 页使用预设下拉加自定义兜底：直连 TCP DNS + 代理域名 DoH；模式决定默认解析器。IPv4/IPv6 DNS 同时接管，用户覆盖优先，基础 proxy 优先于 direct，本地域名交回 dnsmasq。详见架构中的 DNS 策略。
- Advanced 页提供“转发配置”，会自动优先使用 nftables，缺失时回退 iptables，并提供能力检测、应用透明代理转发和清理 Stargate 转发；工具只管理 Stargate 自己的规则，不修改 PassWall2/OpenClash 规则。某些固件可能只有 iptables 或缺少 `kmod-nft-*`，此时会自动回退。
- Stargate 透明转发会只读检测 PassWall2、PassWall、OpenClash 等已启用或运行状态；默认发现冲突即拒绝应用，除非操作者明确设置 `safety.allow_proxy_conflict=1` 或临时环境变量 `STARGATE_ALLOW_PROXY_CONFLICT=1`。
- Rules 页改为 Loyalsoldier clash-rules + sing-box GeoIP rule-set 基础规则体系，不随包内置规则数据，也不内置去广告规则。用户需要显式更新规则，后端将 `direct/private/cncidr/lancidr` 合成为直连域名/CIDR rule-set，将 `proxy/gfw/tld-not-cn/telegramcidr` 合成为代理域名/CIDR rule-set，并额外下载 MetaCubeX 的 `geoip-cn/google/facebook/twitter/telegram` `.srs` 供裸 IP 分流使用；页面只暴露黑名单/白名单模式和少量用户覆盖规则，默认出站与代理出站由模式自动决定。
- 黑名单模式保持“命中 Proxy 才代理，命中 Direct 或未命中则直连”。透明代理不会因为目标是 TCP/443 就默认代理；HTTPS 代理判断依赖 DNS 劫持带来的域名、TLS/HTTP sniff、基础域名规则和 GeoIP rule-set 命中。用户手写直连仍最高优先级；上游基础规则同时命中 direct 和 proxy 时，proxy 优先，避免 `gstatic.com`、`gvt1.com` 等 Google 相关域名被直连规则提前截走。域名规则未命中时，会先用直连 DNS 解析一次，再用 GeoIP rule-set 对解析出的地址复判，避免 Google/Meta 等裸 IP 被落到默认直连。
- Rules 页提供域名/IP 策略测试。域名结果明确不包含目标 IP 复判或真实连接验证；未命中域名规则时返回需要解析，不把兜底猜测显示成已验证结果。
- Rules 页支持用户直连/代理 IPv4 IP/CIDR，由 sing-box 统一判定；防火墙仅绕过私网/保留地址。基础 GeoIP 补充仍包含 `104.244.43.0/24`、`175.41.128.0/18`，并在域名解析后重新检查。
- 阻断 QUIC 默认开启，在防火墙转发层拒绝受管 LAN 设备的 `UDP/443`，使浏览器或应用回退到 TCP/TLS。该选项只处理 `UDP/443`，不会影响其他 UDP 端口或把普通直连 IP 改成代理。
- nft NAT PREROUTING 为 -110，DNS 在通用 TCP 重定向前；IPv6/QUIC guard 为 PREROUTING -10，避免 NetBird 的外部 FORWARD 自动放行。iptables fallback 仍使用既有链前插逻辑，NetBird guard 兼容性未验收。
- `docs/reference/deployment-notes.md` 记录当前实机部署、分流验证、DNS、QUIC、防火墙和日志排障经验，便于换机器部署时按清单复核。

## 当前实机状态

- 当前 S20M 测试路由器运行 ImmortalWrt `25.12-SNAPSHOT r38139-45f7c116ea`、kernel `6.12.91`、board `clx,s20m`，防火墙为 fw4/nftables，LAN 为 `192.168.6.1/24`，WAN 从上级 `192.168.1.1` 获取地址。
- 该固件使用 `apk`，不是 `opkg`。LuCI 软件包页面已适配 apk；后续缺包用 `apk add`，不要混装 opkg，也不要做全量包升级。
- Stargate LuCI 版已部署到实机；`sing-box` 由系统 apk 安装到 `/usr/bin/sing-box`，当前版本 `1.12.25-r1`。LuCI 服务菜单应出现 Stargate，后端 `/usr/share/stargate/stargate.sh status` 正常返回。
- 当前已配置 AnyTLS 节点，并已更新基础规则。Stargate 处于 enabled/running，透明代理为 redirect 模式，nftables 表 `inet stargate` 已应用；Baidu、Google、GitHub 本机 HTTP 代理检测通过，LAN 透明路径另以规则计数和局域网设备实测确认。
- 防火墙后端识别为 `nft`。nft 规则生成使用 `meta l4proto tcp redirect to :PORT`，直连 CIDR 使用 interval set + `auto-merge`。Stargate 的 PREROUTING 使用 `dstnat - 10`，早于固件常见的 dnsmasq DNS 劫持和其他代理入口；关键规则带计数器，状态以 `/usr/share/stargate/stargate.sh firewall-status` 和 `nft list table inet stargate` 共同确认。
- 实机已做低风险精简：停用文件共享、Docker、OpenClash、Cloudflared、EasyTier、HAProxy、NFS 等非基础服务；保留 network、firewall、dnsmasq、odhcpd、dropbear、uhttpd、rpcd、时间同步和 MTK/系统服务。
- 路由器本机 DNS 已固定补充 dnsmasq 上游 `223.5.5.5` 和 `119.29.29.29`，避免新镜像只写入 IPv6 link-local resolver 时解析失败。
- 近期备份位置：优化前 `/root/stargate-preopt-20260614-002212`，Stargate 安装前 `/root/stargate-install-pre-20260614-003106`。S20M nftables 镜像构建资料见 `tools/s20m-nftables/` 和 `docs/reference/s20m-nftables-build.md`。

## 当前边界

- 不移动或删除 `scripts/stargate.sh`，它仍是当前稳定命令实现。
- 不把项目强行拆成 monorepo；当前没有多个独立运行单元。
- 不新增空的 `apps/`、`packages/` 或复杂工程目录。
- 不从 `third_party/` import、source、复制运行时路径或建立构建依赖。
- LuCI 前端和 IPv4 TCP 透明代理已实现；订阅、多协议导入仍属于未来阶段。

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

下一步按 [NetBird 出口设计](reference/netbird-exit-node.md) 配置测试组、默认路由和专用 DNS；先由远端测试客户端手动选择 S20M，验证入口权限、出口分流、IPv6/QUIC、私网互通及重连后行为，再决定是否扩大启用范围。PassWall2 等其他透明代理仍在运行时，Stargate 透明转发应被拒绝。
