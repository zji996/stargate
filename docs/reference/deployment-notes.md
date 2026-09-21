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
ubus call luci getFeatures 2>/dev/null || true
```

不要为了补依赖直接执行全量包升级。OpenWrt 上全量升级容易引入内核模块、nftables/firewall4 和用户态包版本不匹配。缺什么装什么，安装防火墙相关依赖前先确认当前固件是 fw3/iptables 还是 fw4/nftables。

Stargate 当前只管理自己的 sing-box 配置、服务和防火墙规则，不应停用或改写 PassWall2、OpenClash、NetBird 等其他服务。实机排障时如果需要关闭其他代理，应由操作者明确决定。

内存较小的 OpenWrt 设备不建议同时承担 Stargate 透明代理和 NetBird userspace WireGuard。实机已观测到 NetBird userspace 进程 RSS 可到数十 MB，并在内存紧张时反复成为 OOM victim。更稳的做法是把 NetBird 安装在实际需要组网访问的终端上，路由器只保留普通上游路由/NAT。

## 包管理和安装

OpenWrt 24 后续固件可能使用 `apk` 取代 `opkg`。先看系统特性，不要按习惯混装旧包管理器：

```sh
ubus call luci getFeatures 2>/dev/null || true
command -v apk || true
command -v opkg || true
```

如果结果是 `apk=true`、`opkg=false`，就使用 `apk add` 安装缺失依赖，不要恢复或混装 `opkg`。新版 LuCI 软件包页面已经会按系统特性使用 apk；混装两个包数据库收益很小，反而容易造成依赖状态不一致。

实机安装 Stargate LuCI 版时，优先使用系统包管理器安装 sing-box，再部署本仓库文件：

```sh
apk add sing-box
sing-box version
```

仓库文件对应目标路径：

- `luci-app-stargate/root/*` 展开到 `/`。
- `luci-app-stargate/htdocs/*` 展开到 `/www`。
- `luci-app-stargate/luasrc/*` 展开到 `/usr/lib/lua/luci`。
- `po/zh-cn/stargate.po` 编译为 `stargate.zh-cn.lmo` 后放到 `/usr/lib/lua/luci/i18n/`。

部署后设置可执行权限并刷新 LuCI：

```sh
chmod 755 /etc/init.d/stargate /usr/share/stargate/stargate.sh
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache* /tmp/luci-cache /tmp/rpcdcache
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

未配置节点时，Stargate 服务保持 `disabled` 或 `inactive` 是正常状态。此时后端应仍能返回状态，LuCI 菜单也应出现在索引中：

```sh
/usr/share/stargate/stargate.sh status
/usr/share/stargate/stargate.sh firewall-status
/etc/init.d/stargate status
grep -R "admin/services/stargate\|Stargate" /tmp/luci-indexcache* /tmp/luci-modulecache* 2>/dev/null
```

如果 LuCI JS 菜单不可见，确认 `/usr/share/luci/menu.d/luci-app-stargate.json`、`/www/luci-static/resources/view/stargate/*.js` 和 `/usr/share/rpcd/acl.d/luci-app-stargate.json` 已部署。如果旧式 CBI fallback 不可见，确认 `luasrc` 文件被放到 `/usr/lib/lua/luci/` 下，而不是 `/usr/lib/lua/` 下。

## 推荐启用顺序

1. 只配置节点，不启用透明代理。
2. 保存 Overview 配置；保存动作只写 UCI，不启动服务或应用转发。
3. 需要测试 Stargate 时，再显式执行 `/usr/share/stargate/stargate.sh start`，确认只监听本机 SOCKS/HTTP。
4. 确认 Overview 中 Baidu、Google、GitHub 检测能体现本机代理路径。
5. 在 Rules 页更新基础规则。
6. 用 Rules 页测试策略确认常见目标：
   - `baidu.com` 应为 Direct。
   - `google.com`、`chatgpt.com`、`github.com` 应按规则走 Proxy 或预期路径。
   - 直接测试 Google、Meta、Twitter/X、Telegram 的 IP 时，应优先由 GeoIP proxy rule-set 或内置补丁命中。
7. 确认 PassWall2、PassWall、OpenClash 等其他透明代理已停用后，再勾选透明代理并显式应用转发规则。
8. 从局域网设备访问国内站、海外站、游戏或组网服务，观察是否符合“命中 Proxy 才代理，直连目标保持直连”。

透明代理默认不启用。只有本机代理已经启用后，才应该允许透明代理生效。保存 UCI 不等于运行态切换；关闭运行态应显式执行 `/usr/share/stargate/stargate.sh stop`，它会停止服务、禁用 init 自启并清理 Stargate 防火墙规则。

## 2026-05-12 断网复盘

本次实机问题的直接风险点是 LuCI 保存路径过于激进：Overview 的 Save & Apply 和 CBI fallback 的 `on_after_commit` 会立即调用 `apply-runtime`，init `reload` 也会按 UCI 自动同步运行态。只要页面里留下了 `transparent_proxy=1`，一次普通保存就可能启动 Stargate 并应用透明转发。

透明转发本身会接管 LAN 侧 TCP、DNS 53、IPv6 guard 和 UDP/443 QUIC 阻断；当 PassWall2 已经在管理 DNS、nftables 和 xray 转发时，两个透明代理同时抢入口，国内域名解析和直连流量就可能被送进 Stargate 的未稳定规则或节点路径，表现为国内站无法访问。

修复方向：

- LuCI 保存只写 UCI，不再自动启动、停止或应用转发。
- init `reload` 不再调用 `apply-runtime`，init `start` 不再自动应用防火墙规则。
- 透明转发应用前只读检测 PassWall2、PassWall、OpenClash 等冲突代理，默认拒绝共存。
- `global.auto_start=0` 保持默认，显式启动不会自动打开开机自启。

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

DNS 重定向默认开启，但只有透明代理防火墙规则应用后才真正接管受管设备的 IPv4/IPv6 TCP/UDP 53。IPv6 DNS 绑定固定 LAN 地址并 DNAT 到该地址；不要改成通配监听加 REDIRECT，否则 UDP 回复可能无法还原源端口。DNS 重定向规则必须排在通用透明代理 TCP redirect 规则之前，否则 TCP/53 可能被错误送进透明代理入站。

## QUIC 和 UDP

redirect 模式只处理 IPv4 TCP。它不会代理普通 UDP，也不会代理 QUIC。

阻断 QUIC 的作用是拒绝受管 LAN 设备的 `UDP/443`，让浏览器或应用从 HTTP/3/QUIC 回退到 TCP/TLS。这样透明代理更容易通过 DNS reverse mapping、TLS/HTTP sniff 和规则集识别目标。

阻断 QUIC 不应影响其他 UDP 端口，也不应该把普通直连 IP 改成代理。NetBird、游戏、语音等依赖 UDP 的场景通常不建议启用 TProxy 兜全 UDP；当前更稳的默认方向是 redirect + 只阻断 UDP/443。

## 防火墙经验

防火墙后端自动优先 nftables，缺失时回退 iptables。不同 OpenWrt 固件可能实际只可用其中一种，实机判断应以 Stargate status 和系统命令结果为准。

nft 透明代理使用 PREROUTING NAT -110，IPv6/QUIC guard 使用 PREROUTING filter -10；不能把 nft guard 放回 FORWARD，NetBird 会向其他 FORWARD 链自动插入接受规则。iptables fallback 仍使用既有链前插方式，其 NetBird guard 兼容性尚未验收。清理规则时只清理 Stargate 自己的链或表，不碰其他代理工具。默认发现 PassWall2、PassWall、OpenClash 已启用或运行时拒绝应用透明转发，除非显式设置 `safety.allow_proxy_conflict=1` 或 `STARGATE_ALLOW_PROXY_CONFLICT=1`。

fw4/nftables 上不要照搬 iptables 写法。透明代理全 TCP 匹配应写成 `meta l4proto tcp redirect to :PORT`，不能写成 `tcp redirect`。大量直连 CIDR 应放进命名 interval set；上游 CIDR 可能重叠，set 需要 `auto-merge`，否则会报 `conflicting intervals specified`。

Stargate 的 nft PREROUTING 使用 `dstnat - 10`。一些固件会创建 `inet dnsmasq` 并以 `dstnat - 5` 把所有 UDP/53 提前重定向到 dnsmasq，PassWall2 也可能使用 `dstnat - 1`；如果 Stargate 仍使用默认 `dstnat`，页面会显示防火墙 Active，但 DNS 请求实际永远到不了 sing-box，受污染的解析地址随后会让透明代理连接错误目标。排障时应查看 `nft -a list table inet stargate` 的规则计数器，确认 DNS redirect 和 transparent redirect 都有命中。

防火墙应用失败必须向 `apply-runtime` 透传非零退出码。否则会出现 UCI 已勾选、sing-box 已运行，但 `nft list table inet stargate` 不存在的半成功状态；Overview 也会让人误以为透明代理已接管。

配置应用脚本生成并校验配置后，会以 `STARGATE_CONFIG_READY=1` 调用 init 启动或重启。init 在普通开机启动时仍会按 UCI 生成配置，但收到该标记时只校验现有配置，避免一次保存触发两次 apply 并把 `config.json.bak` 覆盖为当前配置。显式 rollback 重启也必须携带同一标记，否则 init 会立即按当前 UCI 重新生成配置并撤销回滚。

`direct4` / `STARGATE_DIRECT4` 只含私网和保留地址。公网 CIDR 不提前绕过，否则代理域名解析到国内 CDN 时，规则测试会显示 Proxy、实际却走 Direct。国内公网 TCP 进入 sing-box 后仍可直连，需观察核心负载。

iptables 和 nft 后端都必须保护透明代理入站端口，拒绝受管设备直接访问路由器自身的 transparent port。正常 REDIRECT 流量的原始目标不是该端口；nft 后端在 NAT 之后依据 `ct status dnat` 放行真实重定向连接，再拒绝没有 DNAT 状态的直连。缺少这层保护时，sing-box 可能把路由器自身的透明端口继续作为原目标递归拨号，短时间耗尽文件描述符。procd 实例同时显式设置与系统 sing-box 包一致的 `nofile` 高限额，但它只是正常并发余量，不能代替入口保护。

如果上游网络通过 NAT 或静态路由提供额外私网网段，例如 `192.168.8.0/24`，应确认该网段在 `STARGATE_DIRECT4` 直连集合中，并用 `ip route get` 验证它走普通上游路由而不是透明代理或已卸载的组网接口。

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
- DNS 是直连 TCP DNS + 代理域名 DoH；模式决定兜底，用户覆盖优先于基础规则，基础 proxy 优先于 direct。分别测试 IPv4/IPv6、TCP/UDP DNS，以及 `.lan` 内网解析。
- Advanced 应用和清理转发只影响 Stargate 自己的规则。
- Logs 页能查看过滤日志和原始日志。

外部连通性至少验证：

```sh
curl -I --proxy http://127.0.0.1:10809 https://www.google.com/generate_204
curl -I --proxy http://127.0.0.1:10809 https://www.baidu.com/
curl -I --proxy http://127.0.0.1:10809 https://github.com/
```

透明代理启用后，再从一台局域网设备重复验证国内站、海外站和常用应用。若出现 ChatGPT、Google、Meta、Twitter/X 等显示国内 IP，优先检查 DNS 重定向、规则命中、GeoIP `.srs`、QUIC 阻断和服务是否加载了新配置。

NetBird exit node 的当前基础、控制台配置设计和未完成验收见 [出口设计](netbird-exit-node.md)。
