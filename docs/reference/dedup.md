# 去重加速

Codex 这类客户端每一轮都会把整段对话历史重新上传。去重加速在路由器上把这些请求里已经传过的内容换成短引用，出口服务器再还原，所以跨境上行只传新增的部分。

默认关闭。关闭时生成的 sing-box 配置与没有这个功能时逐字节相同。

## 组成

- 路由器：`stargate-dedup` 前端，代码在 `tools/dedup`，与 anytls-go `cmd/dedup` 保持一致，由 `/etc/init.d/stargate-dedup` 管理。
- 出口服务器：anytls-go 的 `dedup back` 解码端，加上带 `-dedup-backend` 参数的 anytls-server。没有解码端的节点照常工作，前端对它们原样转发。

## 开关

```sh
/usr/share/stargate/dedup.sh on 10.0.0.12   # 打开，只对这些设备（IP 或网段）生效
/usr/share/stargate/dedup.sh off            # 关闭
/usr/share/stargate/dedup.sh status         # 开关、前端、压缩率
/usr/share/stargate/dedup.sh ca             # 打印设备需要信任的 CA 证书
```

`on` 会先启动前端，再让 Stargate 重新生成并应用路由；`off` 顺序相反。哪一步失败都会恢复原来的设置。每次切换都会重启一次 Stargate，正在走代理的连接会断开一次。

不带设备参数时沿用上次保存的设备列表。

## 前提

- 列出的设备必须先信任 `dedup.sh ca` 输出的证书。否则打开后，这些设备访问 OpenAI 会报证书错误。CA 在第一次 `on` 时生成，只能为 `domains` 里的域名签发证书。
- 只接管列出的设备访问这些域名的 443 端口 TCP 连接，其他设备和流量不受影响。
- 路由模式为直连时没有可去重的流量，`on` 会拒绝执行。

## 出口不变

主节点算一个通道，每个带专用端口的节点各算一个。连接原本走哪个节点，前端就从哪个节点出去，出口 IP 不变。sing-box 用 SOCKS 用户名区分通道：

- 连接通过 `dedup-out-<通道>` 进入前端；
- 前端经回程入站 `dedup-in` 带着同一个用户名返回；
- `auth_user` 规则再把它送回该通道的节点。

增删节点不需要重启前端。

## 资源

所有通道合计受 cgroup 内存上限约束，默认 300 MiB，超出时内核杀掉前端，不会杀 sing-box。前端崩溃后 1 秒内由 procd 拉起。前端参数变化时，新进程先启动，旧进程再继续接收 3 秒，期间不断流。

## 可选项

UCI `stargate.dedup` 段，一般不需要改：

| 选项 | 默认 | 说明 |
| --- | --- | --- |
| `domains` | `chatgpt.com api.openai.com` | 接管的域名，含子域名；改动后需删除 `/etc/stargate/dedup` 让 CA 重建，设备重新信任 |
| `port` | `10860` | 前端端口；加 1 是回程入站，加 2 是统计接口 |
| `memory_mib` | `300` | 内存上限，索引和在途预算按比例缩放 |
| `compress` | `auto` | 新内容的压缩：`auto`、`huffman`（更省 CPU）或 `off`（只去重） |
