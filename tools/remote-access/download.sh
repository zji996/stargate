#!/bin/sh
set -eu

base=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
target=${1:?usage: download.sh linux_amd64|linux_arm64|windows_amd64|darwin_arm64|darwin_amd64 OUTPUT}
output=${2:?output directory required}
case "$target" in linux_amd64|linux_arm64|windows_amd64|darwin_arm64|darwin_amd64) ;; *) exit 2 ;; esac
mkdir -p "$output"
output=$(CDPATH='' cd -- "$output" && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
frp_version=$(jq -r .frp_version "$base/assets.json")
frp_hash=$(jq -r --arg target "$target" '.frp[$target]' "$base/assets.json")
extension=tar.gz
[ "$target" != windows_amd64 ] || extension=zip
frp_name="frp_${frp_version}_${target}"
curl -fL --retry 2 --connect-timeout 15 -o "$temporary/frp.$extension" "https://github.com/fatedier/frp/releases/download/v$frp_version/$frp_name.$extension"
printf '%s  %s\n' "$frp_hash" "$temporary/frp.$extension" | sha256sum -c -
if [ "$extension" = zip ]; then
  unzip -q "$temporary/frp.zip" -d "$temporary"
  cp "$temporary/$frp_name/frpc.exe" "$output/"
else
  tar -xzf "$temporary/frp.tar.gz" -C "$temporary"
  cp "$temporary/$frp_name/frpc" "$output/"
  [ "$target" != linux_amd64 ] || cp "$temporary/$frp_name/frps" "$output/"
fi
if [ "$target" != linux_arm64 ]; then
  singbox_target=$(printf '%s' "$target" | tr '_' '-')
  singbox_version=$(jq -r .singbox_version "$base/assets.json")
  singbox_hash=$(jq -r --arg target "$singbox_target" '.singbox[$target]' "$base/assets.json")
  name="sing-box-$singbox_version-$singbox_target"
  curl -fL --retry 2 --connect-timeout 15 -o "$temporary/sing-box.$extension" "https://github.com/SagerNet/sing-box/releases/download/v$singbox_version/$name.$extension"
  printf '%s  %s\n' "$singbox_hash" "$temporary/sing-box.$extension" | sha256sum -c -
  if [ "$extension" = zip ]; then
    unzip -q "$temporary/sing-box.zip" -d "$temporary"
    cp "$temporary/$name/sing-box.exe" "$output/"
  else
    tar -xzf "$temporary/sing-box.tar.gz" -C "$temporary"
    cp "$temporary/$name/sing-box" "$output/"
  fi
fi
printf 'Verified upstream binaries in %s\n' "$output"
