#!/bin/sh
set -eu

target=${1:-}

if [ -z "$target" ]; then
  echo "Usage: $0 root@ROUTER_LAN_IP" >&2
  exit 2
fi

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$target" 'sh -s' <<'REMOTE'
set -eu

fail=0

check_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    echo "ok: command $1"
  else
    echo "missing: command $1"
    fail=1
  fi
}

check_pkg() {
  if opkg list-installed "$1" 2>/dev/null | grep -q "^$1 - "; then
    echo "ok: package $1"
  else
    echo "missing: package $1"
    fail=1
  fi
}

echo "=== board ==="
ubus call system board 2>/dev/null || true

echo "=== required commands ==="
check_cmd fw4
check_cmd nft

echo "=== required packages ==="
for pkg in firewall4 nftables-json kmod-nft-core kmod-nft-fib kmod-nft-nat kmod-nft-offload; do
  check_pkg "$pkg"
done

echo "=== nft kernel state ==="
if [ -e /proc/net/netfilter/nf_tables_names ]; then
  echo "ok: /proc/net/netfilter/nf_tables_names"
else
  echo "missing: nf_tables proc state"
  fail=1
fi

if lsmod 2>/dev/null | grep -Eq '(^nf_tables|^nft_)'; then
  lsmod | grep -E '(^nf_tables|^nft_)' | sort
else
  echo "warning: no loaded nf_tables/nft_* modules found; built-in nftables may still be valid"
fi

echo "=== fw4 check ==="
if fw4 check; then
  echo "ok: fw4 check"
else
  echo "failed: fw4 check"
  fail=1
fi

echo "=== nft ruleset smoke test ==="
if nft list ruleset >/tmp/stargate-nft-ruleset.txt; then
  sed -n '1,80p' /tmp/stargate-nft-ruleset.txt
else
  echo "failed: nft list ruleset"
  fail=1
fi

exit "$fail"
REMOTE
