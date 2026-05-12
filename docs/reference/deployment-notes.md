# 实机部署和排障经验

本文记录 Stargate 在 OpenWrt 实机测试中已经验证过的经验。它不是发行说明，也不包含任何具体设备地址、密码或节点信息；换机器部署时按这里的检查顺序走，可以更快定位问题。

## 部署前检查

先确认系统已经具备基础运行条件：

```sh
command -v sing-box
sing-box version
command -v curl
df -h /tmp
free
```

不要为了补依赖直接执行全量 `opkg upgrade`。OpenWrt 上全量升级容易引入内核模块、nftables/firewall4 和用户态包版本不匹配。缺什么装什么，安装防火墙相关依赖前先确认当前固件是 fw3/iptables 还是 fw4/nftables。

Stargate 当前只管理自己的 sing-box 配置、服务和防火墙规则，不应停用或改写 PassWall2、OpenClash、NetBird 等其他服务。实机排障时如果需要关闭其他代理，应由操作者明确决定。

## 推荐启用顺序

1. 只配置节点，不启用透明代理。
2. 勾选本机代理，保存并应用。
3. 确认 Overview 中 Baidu、Google、GitHub 检测能体现本机代理路径。
4. 在 Rules 页更新基础规则。
5. 用 Rules 页测试策略确认常见目标：
   - `baidu.com` 应为 Direct。
   - `google.com`、`chatgpt.com`、`github.com` 应按规则走 Proxy 或预期路径。
   - 直接测试 Google、Meta、Twitter/X、Telegram 的 IP 时，应优先由 GeoIP proxy rule-set 或内置补丁命中。
6. 再勾选透明代理并应用转发规则。
7. 从局域网设备访问国内站、海外站、游戏或组网服务，观察是否符合“命中 Proxy 才代理，直连目标保持直连”。

透明代理默认不启用。只有本机代理已经启用后，才应该允许透明代理生效。关闭代理时，`global.enabled=0` 应停止服务、禁用 init 自启并清理 Stargate 防火墙规则。

## 规则和 GeoIP

黑名单模式的目标是：未命中默认直连，只有命中代理规则的流量走节点。

规则来源分两层：

- 域名和部分 CIDR 来自 Loyalsoldier clash-rules。
- 裸 IP 分流依赖 MetaCubeX sing-box GeoIP `.srs`。

上游规则可能存在空洞。当前已确认 Twitter/X 的 GeoIP 上游覆盖了 `104.244.40.0/23`、`104.244.42.0/24`、`104.244.44.0/22`，但缺少 `104.244.43.0/24`。实机日志也观测到 AWS 新加坡 EC2 段 `175.41.128.0/18` 的裸 IP 被落到默认直连后超时。Stargate 因此内置这些 CIDR 作为代理 GeoIP 补丁，但不在前端暴露为普通配置项。

如果日志里出现国外平台 IP 仍然 `using outbound/direct[direct]` 并超时，先不要直接把站点改成全局代理。应先用 Rules 页测试该域名或 IP：

- 如果域名是 Direct，检查 clash-rules 的 direct/proxy 冲突和路由顺序。
- 如果 IP 是 Direct，检查 GeoIP `.srs` 是否下载成功，或是否需要新增一个内置补丁。
- 如果测试结果是 Proxy 但日志仍走 Direct，检查是否用了旧配置、服务是否重启成功、透明代理是否仍在旧规则上。

## DNS 经验

远端 DNS 默认使用域名 DoH：`https://dns.google/dns-query`。它应通过代理出站，同时显式使用直连 DNS 解析自身域名，避免 DoH 自举连接绕过节点。

如果日志出现类似：

```text
dns: exchange failed for example.com. IN A: unexpected EOF
```

优先检查远端 DNS 出站路径和 DoH 自举配置，而不是简单过滤日志。IP 形式 DoH 在部分网络里更容易被重置或表现为 EOF；域名 DoH 加 `domain_resolver` 更稳定，也更符合当前默认配置。

DNS 重定向默认开启，但只有透明代理防火墙规则应用后才真正接管局域网设备的 TCP/UDP 53。DNS 重定向规则必须排在通用透明代理 TCP redirect 规则之前，否则 TCP/53 可能被错误送进透明代理入站。

## QUIC 和 UDP

redirect 模式只处理 IPv4 TCP。它不会代理普通 UDP，也不会代理 QUIC。

阻断 QUIC 的作用是拒绝受管 LAN 设备的 `UDP/443`，让浏览器或应用从 HTTP/3/QUIC 回退到 TCP/TLS。这样透明代理更容易通过 DNS reverse mapping、TLS/HTTP sniff 和规则集识别目标。

阻断 QUIC 不应影响其他 UDP 端口，也不应该把普通直连 IP 改成代理。NetBird、游戏、语音等依赖 UDP 的场景通常不建议启用 TProxy 兜全 UDP；当前更稳的默认方向是 redirect + 只阻断 UDP/443。

## 防火墙经验

防火墙后端自动优先 nftables，缺失时回退 iptables。不同 OpenWrt 固件可能实际只可用其中一种，实机判断应以 Stargate status 和系统命令结果为准。

透明代理入口需要插到 PREROUTING 和 FORWARD 链前部，避免被已有的 zone、bridge、physdev 或自定义 ACCEPT 规则提前放行。清理规则时只清理 Stargate 自己的链或表，不碰其他代理工具。

直连 CIDR 在 iptables/ipset 可用时会进入 `STARGATE_DIRECT4` 绕过集合。能在 IP 层确定直连的流量应尽量绕过 sing-box，减少日志噪声和路由器负载。

## 日志判断

sing-box 日志里的 `using outbound/direct[direct]: i/o timeout` 不一定是 sing-box 本身故障。常见原因是某个目标被规则判断为直连，但当前网络无法直连访问。

处理顺序：

1. 找出目标域名或 IP。
2. 在 Rules 页测试策略。
3. 如果应代理但被判直连，修规则或 GeoIP。
4. 如果确实应直连但网络不可达，这是环境问题，不应为了压日志盲目全局代理。
5. 只有确认是无价值噪声后，才考虑前端日志过滤；不要用日志过滤掩盖真实分流错误。

Logs 页可以默认隐藏常见直连超时噪声，但原始日志入口要保留，便于复盘真实状态。

## 换机验收清单

每台新机器至少验证：

```sh
/usr/share/stargate/stargate.sh check
/etc/init.d/stargate status
/usr/share/stargate/stargate.sh rules-status
/usr/share/stargate/stargate.sh firewall-status
```

LuCI 侧至少验证：

- Overview 保存/应用能启动本机代理。
- 关闭本机代理后服务和自启状态都会关闭。
- Rules 更新能完成，策略测试不刷新整页也能返回结果。
- DNS 默认值是直连 TCP DNS + 远端域名 DoH。
- Advanced 应用和清理转发只影响 Stargate 自己的规则。
- Logs 页能查看过滤日志和原始日志。

外部连通性至少验证：

```sh
curl -I --proxy http://127.0.0.1:10809 https://www.google.com/generate_204
curl -I --proxy http://127.0.0.1:10809 https://www.baidu.com/
curl -I --proxy http://127.0.0.1:10809 https://github.com/
```

透明代理启用后，再从一台局域网设备重复验证国内站、海外站和常用应用。若出现 ChatGPT、Google、Meta、Twitter/X 等显示国内 IP，优先检查 DNS 重定向、规则命中、GeoIP `.srs`、QUIC 阻断和服务是否加载了新配置。
