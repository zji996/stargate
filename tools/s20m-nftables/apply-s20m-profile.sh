#!/bin/sh
set -eu

src=${1:-}

if [ -z "$src" ] || [ ! -d "$src" ]; then
  echo "Usage: $0 /path/to/openwrt-buildroot" >&2
  exit 2
fi

root=$(cd "$src" && pwd)
dts_dir="$root/target/linux/mediatek/dts-ext"
image_mk="$root/target/linux/mediatek/image/filogic-ext.mk"
base_files="$root/files"

[ -d "$dts_dir" ] || {
  echo "missing dts-ext directory: $dts_dir" >&2
  exit 1
}
[ -f "$image_mk" ] || {
  echo "missing filogic-ext.mk: $image_mk" >&2
  exit 1
}

cp tools/s20m-nftables/mt7986a-clx-s20l.dts "$dts_dir/mt7986a-clx-s20l.dts"
cp tools/s20m-nftables/mt7986a-chuliuxiang-s20m.dts "$dts_dir/mt7986a-chuliuxiang-s20m.dts"

if ! grep -q '^define Device/clx_s20l$' "$image_mk"; then
  cat >>"$image_mk" <<'EOF'

define Device/clx_s20l
  DEVICE_VENDOR := CLX
  DEVICE_MODEL := S20L AX4200
  DEVICE_DTS := mt7986a-clx-s20l
  DEVICE_DTS_DIR := ../dts-ext
  DEVICE_PACKAGES := -automount -block-mount -ntfs3-mount -e2fsprogs \
    -kmod-fs-exfat -kmod-fs-ext4 -kmod-fs-ntfs3 -kmod-fs-vfat \
    -kmod-usb-storage -kmod-usb-storage-extras -kmod-usb-storage-uas \
    -kmod-usb3
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += clx_s20l

define Device/chuliuxiang_s20m
  DEVICE_VENDOR := Chuliuxiang
  DEVICE_MODEL := S20M
  DEVICE_DTS := mt7986a-chuliuxiang-s20m
  DEVICE_DTS_DIR := ../dts-ext
  DEVICE_PACKAGES := -automount -block-mount -ntfs3-mount -e2fsprogs \
    -kmod-fs-exfat -kmod-fs-ext4 -kmod-fs-ntfs3 -kmod-fs-vfat \
    -kmod-usb-storage -kmod-usb-storage-extras -kmod-usb-storage-uas \
    -kmod-usb3
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += chuliuxiang_s20m
EOF
fi

mkdir -p "$base_files/etc/uci-defaults"
cp tools/s20m-nftables/files-uci-disable-wireless "$base_files/etc/uci-defaults/99-s20m-disable-wireless"
chmod +x "$base_files/etc/uci-defaults/99-s20m-disable-wireless"

if [ -f "$root/.config" ]; then
  sed -i \
    -e '/^CONFIG_TARGET_mediatek_filogic_DEVICE_/d' \
    -e '/^# CONFIG_TARGET_mediatek_filogic_DEVICE_/d' \
    -e '/^CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_/d' \
    -e '/^# CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_/d' \
    -e '/^CONFIG_DEFAULT_kmod-crypto-hw-safexcel=/d' \
    -e '/^# CONFIG_DEFAULT_kmod-crypto-hw-safexcel is not set/d' \
    -e '/^CONFIG_PACKAGE_kmod-crypto-hw-safexcel=/d' \
    -e '/^# CONFIG_PACKAGE_kmod-crypto-hw-safexcel is not set/d' \
    -e '/^CONFIG_PACKAGE_kmod-phy-airoha-en8811h=/d' \
    -e '/^# CONFIG_PACKAGE_kmod-phy-airoha-en8811h is not set/d' \
    -e '/^CONFIG_PACKAGE_airoha-en8811h-firmware=/d' \
    -e '/^# CONFIG_PACKAGE_airoha-en8811h-firmware is not set/d' \
    -e '/^CONFIG_PACKAGE_eip197-mini-firmware=/d' \
    -e '/^# CONFIG_PACKAGE_eip197-mini-firmware is not set/d' \
    "$root/.config"
fi

cat \
  tools/s20m-nftables/openwrt-nftables.config \
  tools/s20m-nftables/s20m-no-wifi.config \
  tools/s20m-nftables/s20m-lean.config \
  >> "$root/.config"

echo "applied S20L/S20M profile and config fragments to: $root"
echo "next:"
echo "  cd $root"
echo "  make defconfig"
echo "  make -j\$(nproc) V=s"
