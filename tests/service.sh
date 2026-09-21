#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
limit='procd_set_param limits nofile="1000000 1000000"'

for file in \
  "$repo_dir/luci-app-stargate/root/etc/init.d/stargate" \
  "$repo_dir/scripts/stargate.sh"
do
  grep -Fq "$limit" "$file" || {
    echo "missing sing-box open-file limit: $file" >&2
    exit 1
  }
done

echo "service limit tests passed"
