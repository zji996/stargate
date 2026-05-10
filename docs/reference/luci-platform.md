# LuCI 平台设计

## 第一版目标

第一版 LuCI 前端只做“能稳定生成、检查、应用 sing-box 配置”的最小平台，不复刻 PassWall2 的完整复杂度。

当前包含：

- Overview：较大的状态面板、本机出口连通性测试和启用状态。维护类配置不放在概览页。
- Node：轻量节点列表、手动添加节点、通过 `anytls://` 链接添加节点、行内使用节点、弹窗编辑节点，以及本机 SOCKS/HTTP 入站。
- DNS：直连 TCP DNS + 远端 DoH 的基础组合。
- Rules：基于 GFW rule-set 的基础分流。
- Component Settings：日志级别、sing-box 路径、配置路径、工作目录，以及带解释的生成/检查/应用/重启维护动作。
- Safety：备份、透明代理、防火墙、dnsmasq 开关的显式边界。

未配置当前节点时，Overview 不允许启用 Stargate，Component Settings 不允许执行生成、检查、应用或重启动作。init 脚本也会在启动前检查当前节点，避免通过 LuCI 之外的路径启动一个没有节点的 sing-box 服务。

## 多语言

LuCI 页面使用英文作为源码默认语言，并通过 LuCI gettext 机制提供翻译：

- `po/templates/stargate.pot`：翻译模板。
- `po/zh-cn/stargate.po`：简体中文翻译。

页面语言跟随 OpenWrt 的 LuCI 语言设置。当前目标是原生支持中英文切换，后续增加其他语言时只需补对应 `po/<lang>/stargate.po`。

## LuCI 兼容性

Stargate 同时保留两套 LuCI 页面入口：

- 现代 LuCI JS view：`htdocs/luci-static/resources/view/stargate/*.js`
- 旧式 Lua CBI fallback：`luasrc/controller/stargate.lua` 和 `luasrc/model/cbi/stargate/client/*.lua`

原因是不同 OpenWrt 固件的 LuCI 形态差异很大。2026-05-11 在 `192.168.6.1` 的 BleachWrt / OpenWrt 24.10.3 上实测：

- 设备有 `/usr/share/luci/menu.d/`，但现有服务菜单主要来自 `/usr/lib/lua/luci/controller/*.lua`。
- Lua controller 中调用 `view("stargate/overview")` 会报错：

```text
/usr/lib/lua/luci/controller/stargate.lua:12: attempt to call global 'view' (a nil value)
```

- 该固件需要使用 `cbi("stargate/client/overview")` 这类旧式 CBI 入口。
- 修正后部署到：
  - `/usr/lib/lua/luci/controller/stargate.lua`
  - `/usr/lib/lua/luci/model/cbi/stargate/client/*.lua`
- 清理 `/tmp/luci-indexcache`、`/tmp/luci-modulecache` 并重启 `rpcd`、`uhttpd` 后，LuCI 索引中出现 `luci.controller.stargate` 和 `Stargate`。

因此第一版不要删除 Lua CBI fallback。现代 JS view 可以继续保留，用于支持新版 LuCI；旧固件使用 CBI 页面确保菜单能稳定出现。

### 部署排错顺序

如果 LuCI “服务”菜单里看不到 Stargate：

1. 确认 `/etc/config/stargate` 存在。
2. 确认 `/usr/lib/lua/luci/controller/stargate.lua` 存在，且里面使用 `cbi()`，不是 `view()`。
3. 确认 `/usr/lib/lua/luci/model/cbi/stargate/client/*.lua` 已部署。
4. 清理缓存：

```sh
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

5. 访问 LuCI 后检查索引：

```sh
grep -R "stargate\\|Stargate" /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
```

如果仍然失败，先看 `logread` 中的 `uhttpd` / `luci.dispatcher` 错误，不要直接改业务脚本。

## 从 PassWall2 吸收的经验

PassWall2 的强项是 OpenWrt 集成完整，覆盖节点、订阅、DNS、透明代理、规则、服务状态和日志。但第一版 Stargate 不直接照搬它的复杂菜单和多核心编排。

当前吸收的经验：

- LuCI 作为主要管理入口。
- 服务配置进入 UCI，运行配置由后端生成。
- 用户操作必须经过生成、校验、应用的步骤。
- DNS、规则、透明代理、安全策略分页面表达。
- 系统级接管能力必须显式开关，不作为默认行为。

### 节点列表

Node 页参考 PassWall2 的节点列表体验，但第一版范围更窄：

- 支持手动添加 AnyTLS 节点。
- 支持通过 `anytls://password@host:port/?insecure=1&sni=example.com#name` 链接添加节点。
- 支持在节点列表行中打开弹窗编辑节点。
- 支持通过列表行的单选状态和“使用此节点”按钮把节点设为当前使用节点。
- 支持删除节点。
- “使用”节点只复制到 `config node 'node'`，不会自动启动服务，也不会自动应用透明代理。

暂不支持订阅、批量导入、多协议转换、分组拖拽、自动测速排序。VLESS、Trojan、VMess 等协议应等后端生成器真正支持后再开放，避免 UI 看起来支持但运行层不可用。

## 后端结构

`luci-app-stargate/root/usr/share/stargate/stargate.sh` 是 LuCI 版后端入口，负责：

- 从 `/etc/config/stargate` 读取 UCI 配置。
- 生成 `/etc/stargate/config.json.next`。
- 调用 `sing-box check` 校验。
- 校验通过后替换 `/etc/stargate/config.json`。
- 应用前备份上一份配置。

它不引用 `third_party/`，也不依赖 PassWall2 的 Lua 工具。

## sing-box 二进制

Stargate 默认使用 `/usr/bin/sing-box`，也就是 OpenWrt 系统已安装的 sing-box。路由器实测中 PassWall2 的 `sing_box_file` 也是 `/usr/bin/sing-box`，因此第一版应共用这个系统二进制。

不建议复制 PassWall2 私有文件或另放一份 sing-box：

- 共用系统二进制可以避免版本漂移和重复占用存储。
- Stargate 使用独立配置 `/etc/stargate/config.json`。
- Stargate 使用独立服务 `/etc/init.d/stargate`。
- 不读取或修改 `/etc/config/passwall2`，只在诊断时可只读参考。

## 路由器测试记录

2026-05-10 到 2026-05-11 在 `192.168.6.1` 做过非接管测试和 LuCI 部署测试：

- OpenWrt: 24.10.3, `qualcommax/ipq60xx`, `aarch64_cortex-a53`
- sing-box: `/usr/bin/sing-box`, 1.13.11-r1
- PassWall2: 已安装，`enabled=0`，配置中的 `sing_box_file=/usr/bin/sing-box`
- 空闲测试端口：`127.0.0.1:18080` SOCKS, `127.0.0.1:18081` HTTP
- 隔离 UCI：`UCI_CONFIG_DIR=/tmp/stargate-test/config`
- 生成配置通过 `sing-box check`
- 短时运行只监听 `127.0.0.1:18080` 和 `127.0.0.1:18081`
- 测试后已停止进程并清理 `/tmp/stargate-test`
- LuCI 服务菜单在该固件上需要 Lua controller + CBI 页面，不能只依赖 `menu.d` + JS view。

本次测试发现 sing-box 1.13.11 对缺失 `route.default_domain_resolver` 会报废弃错误，因此生成器已固定写入：

```json
"default_domain_resolver": "direct-dns"
```

Overview 的 Baidu / Google / GitHub 测试用于检查路由器本机出口连通性，故意不走 Stargate SOCKS/HTTP 代理。代理节点连通性应后续单独做成节点测试。

连通性检测参考了 PassWall2 的点击式检测体验，但实现上做了更保守的调整：

- 页面只传固定目标 `baidu`、`google`、`github`，后端映射 URL，不接受任意 URL。
- `curl` 使用 `--noproxy '*'`，避免被环境变量代理影响。
- 使用 GET 请求和跳转跟随，不依赖部分站点可能不稳定的 HEAD 行为。
- 返回 HTTP 状态、总耗时、DNS/TCP/TLS 阶段耗时，以及 `ip route get` 看到的 `dev` / `src`。
- 这样在 Tailscale、策略路由、多 WAN 或默认路由变化后，页面能看出本机实际出口，而不是只显示一个模糊失败。

## DNS 设计

第一版默认组合：

- `local`：系统本地解析器，作为兜底。
- `direct-dns`：直连 DNS，默认 `tcp://223.5.5.5`。
- `remote-doh`：远端 DoH，默认 `https://1.1.1.1/dns-query`，通过 `anytls-out` 出站。
- `route.default_domain_resolver`：默认 `direct-dns`，用于解析出站服务器域名，避免依赖 sing-box 1.12 后的废弃行为。

这对应用户希望的“tcp doh 的 dns”：直连侧优先 TCP，代理侧优先 DoH。后续可以继续扩展 DoT、HTTP/3、FakeIP 和 DNS hijack，但第一版不默认接管局域网 DNS。

## GFW 分流设计

第一版使用 sing-box `rule_set`：

- 默认 rule-set 路径：`/usr/share/stargate/rules/gfw.json`
- 格式：`source`
- 命中 GFW rule-set 时走 `anytls-out`
- 未命中默认 `direct`
- 私有 IP 默认 `direct`

当前 `gfw.json` 只是基础种子规则，用来建立机制。后续应增加规则更新、规则校验、source 到 binary 的编译和回滚。

## 暂不启用的能力

这些开关已经在 Safety 页面表达，但第一版后端不执行系统接管：

- 透明代理
- 防火墙规则管理
- dnsmasq 接管
- DHCP 下发 DNS 修改

后续实现这些能力时，必须先做 dry-run、环境探测和失败回滚。
