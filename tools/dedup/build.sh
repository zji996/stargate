#!/bin/sh
set -eu

# stargate-dedup is anytls-go's cmd/dedup built from a pinned upstream commit;
# Stargate keeps no copy of its source and never builds from third_party/.
# godebug.go there only takes effect with Go 1.27 or newer; older toolchains
# build a back whose TLS handshakes differ from a Go 1.27 client's, so the
# toolchain is pinned too (go downloads it when missing).
repository=https://github.com/zji996/anytls-go.git
commit=77afc500473478c00a4d784486da4e813815e99b
base=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
output=${1:-"$base/../../.local/dedup-build"}
mkdir -p "$output"
output=$(CDPATH='' cd -- "$output" && pwd)
source=$(mktemp -d)
trap 'rm -rf "$source"' EXIT
git -C "$source" init -q
git -C "$source" fetch -q --depth 1 "$repository" "$commit"
git -C "$source" checkout -q FETCH_HEAD
[ "$(git -C "$source" rev-parse HEAD)" = "$commit" ] || {
  echo "fetched anytls-go does not match $commit" >&2
  exit 1
}
cd "$source"
export GOTOOLCHAIN="${GOTOOLCHAIN:-go1.27.2}"
case "$(go env GOVERSION)" in
  go1.2[7-9]*|go1.[3-9][0-9]*) ;;
  *) echo "stargate-dedup needs Go 1.27 or newer, got $(go env GOVERSION)" >&2; exit 1 ;;
esac
for target in linux_arm64 linux_amd64; do
  mkdir -p "$output/$target"
  CGO_ENABLED=0 GOOS="${target%_*}" GOARCH="${target#*_}" go build -trimpath -buildvcs=false -ldflags='-s -w' -o "$output/$target/stargate-dedup" ./cmd/dedup
done
printf 'Built stargate-dedup %s in %s\n' "$(printf '%s' "$commit" | cut -c1-12)" "$output"
