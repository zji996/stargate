#!/bin/sh
set -eu

repo_url=${REPO_URL:-https://github.com/chasey-dev/immortalwrt-mt798x-rebase.git}
branch=${BRANCH:-25.12}
workdir=${1:-tmp/build/s20m-nftables}
src="$workdir/source"
overlay="$workdir/overlay"
out="$workdir/out"

mkdir -p "$workdir" "$overlay" "$out"

if [ ! -d "$src/.git" ]; then
  git clone --depth 1 --branch "$branch" "$repo_url" "$src"
else
  git -C "$src" fetch --depth 1 origin "$branch"
  git -C "$src" checkout "$branch"
  git -C "$src" reset --hard "origin/$branch"
fi

mkdir -p \
  "$overlay/target/linux/mediatek/dts-ext" \
  "$overlay/target/linux/mediatek/image" \
  "$overlay/files/etc/uci-defaults"

cp tools/s20m-nftables/openwrt-nftables.config "$workdir/nftables.config"
cp tools/s20m-nftables/s20m-no-wifi.config "$workdir/s20m-no-wifi.config"
cp tools/s20m-nftables/files-uci-disable-wireless "$overlay/files/etc/uci-defaults/99-s20m-disable-wireless"
chmod +x "$overlay/files/etc/uci-defaults/99-s20m-disable-wireless"

cat >"$workdir/README-next-steps.md" <<'EOF'
# S20M nftables build workspace

This workspace clones the closest known 6.12 MT798x buildroot and stages
Stargate's nftables/no-wifi config fragments.

Manual build steps:

```sh
cd tmp/build/s20m-nftables/source
./scripts/feeds update -a
./scripts/feeds install -a
cat ../nftables.config ../s20m-no-wifi.config >> .config
make defconfig
make menuconfig
make -j$(nproc) V=s
```

Before building, add or verify the exact S20L/S20M device DTS and image
profile. Do not flash an S20P image on S20M.
EOF

cat >"$workdir/build.env" <<EOF
REPO_URL=$repo_url
BRANCH=$branch
SOURCE=$src
OVERLAY=$overlay
OUT=$out
EOF

echo "prepared: $workdir"
echo "source:   $src"
echo "next:     $workdir/README-next-steps.md"

