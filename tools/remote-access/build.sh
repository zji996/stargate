#!/bin/sh
set -eu

base=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
output=${1:-"$base/../../.local/remote-build"}
mkdir -p "$output"
output=$(CDPATH='' cd -- "$output" && pwd)
cd "$base"
for target in linux_amd64 linux_arm64 windows_amd64 darwin_arm64 darwin_amd64; do
  platform=${target%_*}
  architecture=${target#*_}
  suffix=''
  [ "$platform" != windows ] || suffix='.exe'
  mkdir -p "$output/$target"
  CGO_ENABLED=0 GOOS="$platform" GOARCH="$architecture" go build -trimpath -ldflags='-s -w' -o "$output/$target/stargate-remote$suffix" .
done
printf 'Built remote-access binaries in %s\n' "$output"
