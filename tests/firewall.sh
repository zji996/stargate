#!/bin/sh
set -eu
repo_dir="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/luci-app-stargate/root/usr/share/stargate/lib/firewall.sh"
. "$repo_dir/luci-app-stargate/root/usr/share/stargate/lib/rules.sh"
test_dir="$(mktemp -d)"
trap 'rm -f "$test_dir/batch" "$test_dir/calls"; rmdir "$test_dir"' EXIT
firewall_lan_ifaces() { printf 'br-lan\n'; }
rules_custom_direct_ips=203.0.113.0/24
rules_direct_rule_set="$test_dir/direct.json"
printf '{ "ip_cidr": ["198.51.100.0/24"] }\n' > "$rules_direct_rule_set"
if firewall_direct_bypass_cidrs all | grep -Eq '203\.0\.113|198\.51\.100'; then
  echo 'public IP bypass would override domain policy' >&2; exit 1
fi
rm "$rules_direct_rule_set"
netbird_proxy=1
netbird_interface=wt0
[ "$(firewall_managed_ifaces)" = "$(printf 'br-lan\nwt0')" ]
netbird_proxy=0
[ "$(firewall_managed_ifaces)" = br-lan ]
netbird_proxy=1
netbird_interface=br-lan
[ "$(firewall_managed_ifaces)" = br-lan ]
netbird_interface=wt0
transparent_mode=redirect
transparent_port=12345
dns_hijack=1
dns_hijack_port=1053
dns_ipv6_address=fd00::1
rules_block_quic=1
tmp_prefix="$test_dir/stargate"
reject_batch=0
nft() {
  printf '%s\n' "$*" >> "$test_dir/calls"
  case "$1" in
    list) return 0 ;;
    -c) cp "$3" "$test_dir/batch"; return "$reject_batch" ;;
    -f) return 0 ;;
    *) echo "unexpected nft mutation: $*" >&2; return 1 ;;
  esac
}
firewall_apply_nft
grep -q '^delete table inet stargate$' "$test_dir/batch"
grep -q '"br-lan", "wt0".*meta nfproto ipv4.*redirect' "$test_dir/batch"
grep -q 'meta nfproto ipv6 udp dport 53.*dnat ip6 to \[fd00::1\]:1053' "$test_dir/batch"
grep -q 'meta nfproto ipv6 tcp dport 53.*dnat ip6 to \[fd00::1\]:1053' "$test_dir/batch"
grep -q 'fib daddr type != local.*overlay private bypass' "$test_dir/batch"
grep -q 'type filter hook prerouting priority filter - 10' "$test_dir/batch"
grep -q 'tcp dport 12345 ct status dnat.*return.*Stargate transparent redirected input' "$test_dir/batch"
grep -q 'tcp dport 12345.*reject.*Stargate transparent input guard' "$test_dir/batch"
grep -q 'fib daddr type local.*Stargate local input' "$test_dir/batch"
if grep -q 'hook forward' "$test_dir/batch"; then
  echo 'NetBird can override a forward guard' >&2; exit 1
fi
grep -q 'Stargate overlay private bypass' "$test_dir/batch"
grep -q '"br-lan", "wt0".*meta nfproto ipv6.*reject' "$test_dir/batch"
reject_batch=1
: > "$test_dir/calls"
if firewall_apply_nft; then echo 'invalid nft batch accepted' >&2; exit 1; fi
if grep -q '^-f\|^delete' "$test_dir/calls"; then echo 'modified nft on failed validation' >&2; exit 1; fi
reject_batch=0
netbird_proxy=0
dns_hijack=0
rules_block_quic=0
firewall_apply_nft
if grep -q 'wt0\|dport 53\|QUIC block' "$test_dir/batch"; then echo 'disabled feature generated rules' >&2; exit 1; fi
allow_proxy_conflict=0
STARGATE_ALLOW_PROXY_CONFLICT=0
firewall_conflicting_proxy() { printf 'passwall2 enabled'; return 0; }
if firewall_require_no_proxy_conflict >/dev/null 2>&1; then
  echo 'conflicting proxy was not rejected' >&2; exit 1
fi
allow_proxy_conflict=1
firewall_require_no_proxy_conflict
allow_proxy_conflict=0
STARGATE_ALLOW_PROXY_CONFLICT=1
firewall_require_no_proxy_conflict
