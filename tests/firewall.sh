#!/bin/sh
set -eu
repo_dir="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/luci-app-stargate/root/usr/share/stargate/lib/firewall.sh"
test_dir="$(mktemp -d)"
trap 'rm -f "$test_dir/batch" "$test_dir/calls"; rmdir "$test_dir"' EXIT
firewall_lan_ifaces() { printf 'br-lan\n'; }
firewall_direct_bypass_cidrs() { printf '10.0.0.0/8\n'; }
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
