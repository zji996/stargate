# S20M nftables 固件适配

本文记录把当前 S20M/S20L HWRT 固件迁移到 `fw4`/`nftables` 的低风险做法。当前实机是：

- 系统：HWRT / 24.10.5
- target：`mediatek/filogic`
- arch：`aarch64_cortex-a53`
- kernel：`6.12.90`
- 当前防火墙：`fw3` + legacy iptables

## 结论

当前机器不能通过 `opkg install firewall4` 原地升级。feed 里有 `firewall4` 和 `nftables-json`，但没有匹配当前 kernel ABI 的 `kmod-nft-core`、`kmod-nft-fib`、`kmod-nft-offload`、`kmod-nft-nat`。nftables 缺的是内核能力，用户态包不能单独解决。

正确路径是用同一套 HWRT/OpenWrt 源码和同一 target 重编固件，把 `firewall4` 和 `kmod-nft-*` 编进镜像，再整包 sysupgrade。

2026-06-13 已用 `chasey-dev/immortalwrt-mt798x-rebase` 的 `25.12` 分支完成一次 S20M 迁移镜像构建：

```text
tmp/adapted/s20m-immortalwrt-25.12-nftables-20260613-sysupgrade.bin
sha256: 523487c7cb19abb253dae024dcce321ec095b9ecd46ae59a16322faa7a77aa50
```

镜像元数据：

- `supported_devices`: `chuliuxiang,s20m`
- `BOARD`: `chuliuxiang_s20m`
- 版本：ImmortalWrt `25.12-SNAPSHOT`
- target：`mediatek/filogic`
- kernel package ABI：`6.12.91-r1`

已验证 manifest 包含 `firewall4`、`nftables-json`、`kmod-nft-core`、`kmod-nft-fib`、`kmod-nft-nat`、`kmod-nft-offload`、`kmod-nft-socket`、`kmod-nft-tproxy`、`iptables-nft`、`ip6tables-nft`、`dnsmasq-full`；未包含旧 `firewall` 和无线主栈。该分支默认仍带 `e2fsprogs`、USB storage、exfat/ext4/ntfs3/vfat 等存储支持包，当前视为非阻塞冗余，不为了精简继续扩大 buildroot 默认包裁剪范围。

## 构建要求

必须对齐：

- `DISTRIB_TARGET=mediatek/filogic`
- `DISTRIB_ARCH=aarch64_cortex-a53`
- kernel release/ABI 与最终镜像一致
- 设备 DTS/镜像 profile 支持 `clx,s20l` 或能按本文后处理为 `chuliuxiang_s20m`

不要把其他 OpenWrt 或其他 kernel 的 `kmod-nft-*` 拿到当前系统上安装。OpenWrt kmod 与内核 ABI 强绑定，混装会导致模块无法加载，严重时防火墙不可用。

## 编译配置

在 HWRT/OpenWrt 完整 buildroot 中合并：

```sh
cat /path/to/stargate/tools/s20m-nftables/openwrt-nftables.config >> .config
make defconfig
```

核心包：

- `firewall4`
- `nftables-json`
- `kmod-nft-core`
- `kmod-nft-fib`
- `kmod-nft-nat`
- `kmod-nft-offload`
- `kmod-nft-socket`
- `kmod-nft-tproxy`
- `dnsmasq-full`

第一版迁移镜像建议保留 `iptables-nft` 和 `ip6tables-nft`，方便旧诊断命令或第三方包过渡。确认稳定后再考虑进一步去掉兼容层。

当前可用的近源构建准备脚本：

```sh
sh tools/s20m-nftables/prepare-chasey-build.sh
```

该脚本会拉取 `chasey-dev/immortalwrt-mt798x-rebase` 的 `25.12` 分支并准备 nftables 与 S20M 无无线配置片段。这个源码树已经包含 6.12 内核、`firewall4`、`nftables` 和 MT7986 扩展设备机制，但目前只确认有 `clx,s20p`，不能直接刷到 S20M。刷机前必须补齐或核对 S20L/S20M 的 DTS 与 image profile。

如果已经有完整 buildroot，可以直接应用本仓库准备好的 S20L/S20M profile：

```sh
sh tools/s20m-nftables/apply-s20m-profile.sh /path/to/openwrt-buildroot
```

该脚本会写入：

- `target/linux/mediatek/dts-ext/mt7986a-clx-s20l.dts`
- `target/linux/mediatek/dts-ext/mt7986a-chuliuxiang-s20m.dts`
- `target/linux/mediatek/image/filogic-ext.mk` 的 `clx_s20l` 与 `chuliuxiang_s20m` profile
- `files/etc/uci-defaults/99-s20m-disable-wireless`
- `.config` 中 nftables 和无无线配置片段

WSL 环境里如果 `PATH` 带有 `/mnt/c/Program Files/...` 之类 Windows 路径，GNU `find -execdir` 可能拒绝执行。构建时使用干净 `PATH`：

```sh
cd tmp/build/s20m-nftables/source
env PATH='/home/zji/.nvm/versions/node/v24.15.0/bin:/home/zji/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/lib/wsl/lib' \
  DOWNLOAD_MIRROR='https://sources.cdn.openwrt.org;https://sources.openwrt.org' \
  make -j"$(nproc)" V=s
```

## ImageBuilder 限制

只有在 ImageBuilder 自带 package 目录里已经存在匹配的 `kmod-nft-*` 时，才能用 `tools/s20m-nftables/packages-minimal.txt` 做 ImageBuilder 包清单。

当前这台 HWRT 实机的公共 opkg feed 没有这些 kmod，所以 ImageBuilder 方案大概率不适用；优先使用完整 buildroot。

## S20M 适配后处理

如果编译产物是 S20L tar sysupgrade 包，可以用：

```sh
sh tools/s20m-nftables/adapt-sysupgrade-board.sh \
  /path/to/s20l-sysupgrade.bin \
  tmp/adapted/s20m-nftables-sysupgrade.bin \
  chuliuxiang_s20m
```

该脚本只修改 sysupgrade tar 顶层目录和 `CONTROL` 里的 `BOARD=`，不会修改 kernel/rootfs。刷前必须手动执行：

```sh
scp tmp/adapted/s20m-nftables-sysupgrade.bin root@ROUTER_LAN_IP:/tmp/
ssh root@ROUTER_LAN_IP 'sysupgrade -T /tmp/s20m-nftables-sysupgrade.bin'
```

只有 `sysupgrade -T` 返回成功，才进入手动刷机。

## 刷前检查

```sh
sh tools/s20m-nftables/collect-router-facts.sh root@ROUTER_LAN_IP \
  > tmp/s20m-nftables-before.txt
```

至少保存：

- `/etc/config/network`
- `/etc/config/firewall`
- `/etc/config/dhcp`
- `/etc/config/dropbear`
- 当前 sysupgrade 配置备份
- 当前可启动旧固件
- U-Boot Web 恢复方式

已知 U-Boot Web 恢复通常使用设备环境变量里的 `ipaddr` 和 `serverip`：

- 路由器：`UBOOT_IPADDR`
- 电脑静态地址：`UBOOT_SERVERIP/24`
- 上电时按住 Reset 进入恢复页

## 手动上传和刷机

当前路由器没有 sing-box 本机代理，不需要让路由器联网下载镜像；从本机直接 `scp` 上传到 `/tmp`：

```sh
IMG=tmp/adapted/s20m-immortalwrt-25.12-nftables-20260613-sysupgrade.bin
ROUTER=root@ROUTER_LAN_IP
sha256sum "$IMG"
scp "$IMG" "$ROUTER":/tmp/s20m-nftables-sysupgrade.bin
ssh "$ROUTER" 'sha256sum /tmp/s20m-nftables-sysupgrade.bin'
ssh "$ROUTER" 'sysupgrade -T /tmp/s20m-nftables-sysupgrade.bin'
```

刷前先做配置备份：

```sh
ROUTER=root@ROUTER_LAN_IP
ssh "$ROUTER" 'sysupgrade -b /tmp/backup-before-s20m-nftables.tar.gz'
scp "$ROUTER":/tmp/backup-before-s20m-nftables.tar.gz tmp/backups/
ssh "$ROUTER" 'ubus call system board; cat /proc/cmdline; cat /proc/mtd 2>/dev/null || true; ls -l /dev/mmcblk* 2>/dev/null || true'
```

如果 `sysupgrade -T` 通过：

```sh
ssh "$ROUTER" 'sysupgrade -n /tmp/s20m-nftables-sysupgrade.bin'
```

如果 `sysupgrade -T` 只因为当前系统仍识别为 S20L 适配包而报 board metadata 不匹配，且镜像大小和格式检查没有其他错误，可以手动决定强制刷：

```sh
ssh "$ROUTER" 'sysupgrade -F -n /tmp/s20m-nftables-sysupgrade.bin'
```

不要在镜像格式、大小、解包或存储介质检查失败时使用 `-F`。这里推荐 `-n`，因为这是从 S20L 适配固件切换到 S20M profile，并同时切换防火墙栈。

## 刷后验证

刷机后先不要启用 Stargate 透明代理，先确认系统防火墙：

```sh
sh tools/s20m-nftables/verify-router-nftables.sh root@ROUTER_LAN_IP
```

手动检查：

```sh
ssh root@ROUTER_LAN_IP
fw4 check
/etc/init.d/firewall restart
nft list ruleset
opkg list-installed | grep -E '^(firewall4|nftables|kmod-nft)'
ping -c 3 WAN_GATEWAY_IP
ping -c 3 223.5.5.5
nslookup openwrt.org 127.0.0.1
```

通过后再检查 Stargate：

```sh
/usr/share/stargate/stargate.sh firewall-status
```

期望看到后端为 `nft`。如果透明代理仍关闭，`Active` 可以是 `no`；这表示没有写 Stargate 自己的透明代理规则，不代表 fw4 失败。

额外确认无线和旧防火墙没有回来：

```sh
ROUTER=root@ROUTER_LAN_IP
ssh "$ROUTER" 'opkg list-installed | grep -E "^(firewall|firewall4|nftables-json|kmod-nft|iptables-nft|ip6tables-nft|wpad|kmod-mt76|kmod-mt7915|mac80211|cfg80211)"'
```

## 回滚

如果刷后 LAN 可访问但防火墙异常：

```sh
/etc/init.d/firewall stop
fw4 check
logread | grep -Ei 'fw4|nft|firewall'
```

如果确认新镜像不可用，直接通过 LuCI/SSH 手动 sysupgrade 回旧固件。若 LAN 不可访问，使用 U-Boot Web 恢复旧固件。

U-Boot 存在会显著降低变砖风险，但不是绝对保证。只做 sysupgrade 通常不会写 bootloader/BL2/FIP；如果误刷了错误存储布局、覆盖了启动链或断电导致关键分区损坏，仍可能需要串口或更底层恢复。
