#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/luci-app-stargate/root/usr/share/stargate/lib/common.sh"

validate_port_value 1 "test port"
validate_port_value 65535 "test port"

for invalid in 0 65536 text ''; do
  if validate_port_value "$invalid" "test port" 2>/dev/null; then
    echo "invalid port accepted: $invalid" >&2
    exit 1
  fi
done

[ "$(uri_decode 'pass+word')" = 'pass+word' ] || {
  echo "URI decoder changed a literal plus" >&2
  exit 1
}
