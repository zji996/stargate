#!/bin/sh
set -eu

# godebug.go only takes effect with Go 1.27 or newer; older toolchains build a
# back whose TLS handshakes differ from a Go 1.27 client's.
base=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
output=${1:-"$base/../../.local/dedup-build"}
mkdir -p "$output"
output=$(CDPATH='' cd -- "$output" && pwd)
cd "$base"
for target in linux_arm64 linux_amd64; do
  mkdir -p "$output/$target"
  CGO_ENABLED=0 GOOS="${target%_*}" GOARCH="${target#*_}" go build -trimpath -ldflags='-s -w' -o "$output/$target/stargate-dedup" .
done
printf 'Built stargate-dedup in %s\n' "$output"
