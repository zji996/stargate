#!/bin/sh
set -eu
repo_dir="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/luci-app-stargate/root/usr/share/stargate/lib/common.sh"
. "$repo_dir/luci-app-stargate/root/usr/share/stargate/lib/rules.sh"
. "$repo_dir/luci-app-stargate/root/usr/share/stargate/lib/config.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
work_dir="$test_dir"
config_file="$test_dir/config.json"
singbox_bin=/nonexistent
for name in direct proxy; do
  printf '{"version":3,"rules":[]}\n' > "$test_dir/$name.json"
  : > "$test_dir/$name.srs"
done
uci() { return 1; }
firewall_dns_ipv6_address() { printf fd00::1; }
uci_get() {
  case "$1.$2" in
    rules.mode) printf '%s' "$test_mode" ;;
    node.server) printf node.example ;;
    node.password) printf test-only ;;
    inbound.transparent_proxy) printf 1 ;;
    rules.direct_rule_set) printf '%s/direct.json' "$test_dir" ;;
    rules.proxy_rule_set) printf '%s/proxy.json' "$test_dir" ;;
    rules.geoip_direct_rule_set|rules.geoip_proxy_rule_sets) printf '' ;;
    rules.custom_direct_domains) printf 'both.example\nFORCE-DIRECT.EXAMPLE' ;;
    rules.custom_proxy_domains) printf 'both.example\nforce-proxy.example' ;;
    rules.custom_direct_ips) printf 198.51.100.7 ;;
    rules.custom_proxy_ips) printf 203.0.113.7 ;;
    *) printf '%s' "$3" ;;
  esac
}
for test_mode in blacklist whitelist global_proxy direct; do
  generated="$(generate_config)"
  cp "$generated" "$test_dir/$test_mode.json"
  # The policy inspector must not consult stale base files in fixed modes.
  rules_test 104.244.43.7 > "$test_dir/$test_mode.ip.txt"
  rules_test printer.lan > "$test_dir/$test_mode.local.txt"
done
python3 "$repo_dir/tests/routing.py" "$test_dir"
