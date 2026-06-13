#!/bin/sh
set -eu

kernel=${1:-tmp/inspect-s20l-root/sysupgrade-clx_s20l/kernel}
outdir=${2:-tmp/s20m-nftables-dtb}

[ -f "$kernel" ] || {
  echo "kernel image not found: $kernel" >&2
  exit 1
}

mkdir -p "$outdir"

python3 - "$kernel" "$outdir/s20l.dtb" <<'PY'
import sys
from pathlib import Path

data = Path(sys.argv[1]).read_bytes()
magic = b"\xd0\x0d\xfe\xed"
offset = data.find(magic)
if offset < 0:
    raise SystemExit("FDT magic not found")

Path(sys.argv[2]).write_bytes(data[offset:])
print(f"dtb_offset={offset}")
print(f"dtb_path={sys.argv[2]}")
PY

if command -v dtc >/dev/null 2>&1; then
  dtc -I dtb -O dts -o "$outdir/s20l.dts" "$outdir/s20l.dtb"
  echo "dts_path=$outdir/s20l.dts"
else
  echo "dtc not found; install device-tree-compiler to generate $outdir/s20l.dts" >&2
fi

