#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage:
  adapt-sysupgrade-board.sh INPUT_SYSUPGRADE OUTPUT_SYSUPGRADE [BOARD_ID]

Default BOARD_ID:
  chuliuxiang_s20m

This rewrites an OpenWrt/HWRT tar sysupgrade package top-level directory and
CONTROL BOARD value. It does not modify kernel or rootfs content.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  usage >&2
  exit 2
fi

input=$1
output=$2
board=${3:-chuliuxiang_s20m}

[ -f "$input" ] || {
  echo "input sysupgrade image not found: $input" >&2
  exit 1
}

case "$board" in
  *[!A-Za-z0-9_.,-]*|'')
    echo "invalid board id: $board" >&2
    exit 1
    ;;
esac

output_dir=$(dirname "$output")
output_base=$(basename "$output")
mkdir -p "$output_dir"
output_abs=$(cd "$output_dir" && pwd)/$output_base

work=$(mktemp -d "${TMPDIR:-/tmp}/s20m-sysupgrade.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

tar -xf "$input" -C "$work"
src_dir=$(find "$work" -mindepth 1 -maxdepth 1 -type d | sed -n '1p')
[ -n "$src_dir" ] || {
  echo "no sysupgrade directory found in $input" >&2
  exit 1
}

dest_dir="$work/sysupgrade-$board"
if [ "$src_dir" != "$dest_dir" ]; then
  rm -rf "$dest_dir"
  mv "$src_dir" "$dest_dir"
fi

for required in kernel root; do
  [ -f "$dest_dir/$required" ] || {
    echo "missing $required in sysupgrade image" >&2
    exit 1
  }
done

control="$dest_dir/CONTROL"
if [ -f "$control" ] && grep -q '^BOARD=' "$control"; then
  sed "s/^BOARD=.*/BOARD=$board/" "$control" >"$control.tmp"
  mv "$control.tmp" "$control"
else
  printf 'BOARD=%s\n' "$board" >"$control"
fi

(
  cd "$work"
  tar -cf "$output_abs" "sysupgrade-$board"
)

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$output_abs"
fi

