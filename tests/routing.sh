#!/bin/sh
set -eu
repo_dir="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/luci-app-stargate/root/usr/share/stargate/lib/common.sh"
. "$repo_dir/luci-app-stargate/root/usr/share/stargate/lib/rules.sh"
. "$repo_dir/luci-app-stargate/root/usr/share/stargate/lib/config.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
app="stargate"
work_dir="$test_dir"
config_file="$test_dir/config.json"
singbox_bin=/nonexistent
for name in direct proxy; do
  printf '{"version":3,"rules":[]}\n' > "$test_dir/$name.json"
  : > "$test_dir/$name.srs"
done
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
    node_jp.type) printf anytls ;;
    node_jp.server) printf jp.example.com ;;
    node_jp.server_port) printf 443 ;;
    node_jp.password) printf jp-pass ;;
    node_jp.sni) printf '' ;;
    node_jp.insecure) printf 1 ;;
    node_jp.enable_port) printf 1 ;;
    node_jp.socks_port) printf 10818 ;;
    node_jp.http_port) printf 10819 ;;
    node_jp.listen) printf 0.0.0.0 ;;
    node_us.type) printf anytls ;;
    node_us.server) printf us.example.com ;;
    node_us.server_port) printf 443 ;;
    node_us.password) printf us-pass ;;
    node_us.sni) printf '' ;;
    node_us.insecure) printf 1 ;;
    node_us.enable_port) printf 1 ;;
    node_us.socks_port) printf 10828 ;;
    node_us.http_port) printf 10829 ;;
    node_us.listen) printf '%s' "${listen_case:-0.0.0.0}" ;;
    # Same server/port/password as the active node: must reuse anytls-out.
    node_main.type) printf anytls ;;
    node_main.server) printf node.example ;;
    node_main.server_port) printf 443 ;;
    node_main.password) printf test-only ;;
    node_main.enable_port) printf 1 ;;
    node_main.socks_port) printf '%s' "${conflict_case:-10838}" ;;
    # Dedicated port disabled: no inbound, no outbound, no rules.
    node_off.type) printf anytls ;;
    node_off.server) printf off.example.com ;;
    node_off.password) printf off-pass ;;
    node_off.enable_port) printf 0 ;;
    node_off.socks_port) printf 10848 ;;
    # Anonymous section ids are not valid shell identifiers and must be skipped.
    "@node_item[0].enable_port") printf 1 ;;
    "@node_item[0].socks_port") printf 10858 ;;
    *) printf '%s' "$3" ;;
  esac
}
uci() {
  if [ "$1" = "-q" ] && [ "$2" = "show" ] && [ "$3" = "stargate" ]; then
    printf 'stargate.node_jp=node_item\nstargate.node_jp.server=jp.example.com\nstargate.node_us=node_item\nstargate.node_main=node_item\nstargate.node_off=node_item\nstargate.@node_item[0]=node_item\n'
    return 0
  fi
  return 1
}
for test_mode in blacklist whitelist global_proxy direct; do
  generated="$(generate_config)"
  cp "$generated" "$test_dir/$test_mode.json"
  # The policy inspector must not consult stale base files in fixed modes.
  rules_test 104.244.43.7 > "$test_dir/$test_mode.ip.txt"
  rules_test printer.lan > "$test_dir/$test_mode.local.txt"
done
test_mode=blacklist
# A dedicated port equal to the main SOCKS port must be rejected before sing-box check.
if (conflict_case=10808 generate_config >/dev/null 2>"$test_dir/conflict.err"); then
  echo "expected dedicated port conflict to fail" >&2
  exit 1
fi
grep -q "conflicts with another Stargate port" "$test_dir/conflict.err"
# Two dedicated nodes sharing a port must be rejected as well.
if (conflict_case=10818 generate_config >/dev/null 2>"$test_dir/conflict2.err"); then
  echo "expected duplicate dedicated port to fail" >&2
  exit 1
fi
# A listen address that is not an IP must be rejected.
if (listen_case=lan generate_config >/dev/null 2>"$test_dir/listen.err"); then
  echo "expected invalid listen address to fail" >&2
  exit 1
fi
grep -q "IPv4 or IPv6" "$test_dir/listen.err"
# IPv6 listen addresses are accepted.
listen_case=:: generate_config >/dev/null
python3 "$repo_dir/tests/routing.py" "$test_dir"
