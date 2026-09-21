#!/bin/sh
set -eu

target=${1:-}

if [ -z "$target" ]; then
  echo "Usage: $0 root@ROUTER_LAN_IP" >&2
  exit 2
fi

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$target" 'sh -s' <<'REMOTE'
set -eu

echo "=== openwrt_release ==="
cat /etc/openwrt_release 2>/dev/null || true

echo "=== board ==="
ubus call system board 2>/dev/null || true

echo "=== kernel ==="
uname -a

echo "=== opkg feeds ==="
sed -n '1,160p' /etc/opkg/distfeeds.conf 2>/dev/null || true
sed -n '1,160p' /etc/opkg/customfeeds.conf 2>/dev/null || true

echo "=== installed firewall packages ==="
opkg list-installed 2>/dev/null | grep -E '^(firewall|firewall4|nft|iptables|ip6tables|kmod-nft|kmod-nf-|dnsmasq|ucode)' | sort || true

echo "=== nft module files ==="
find "/lib/modules/$(uname -r)" -maxdepth 1 -type f \( -name '*nft*' -o -name 'nf_tables*' -o -name 'nft_*' \) -print 2>/dev/null | sort || true

echo "=== runtime commands ==="
for cmd in fw3 fw4 nft iptables ip6tables; do
  if command -v "$cmd" >/dev/null 2>&1; then
    printf '%s: %s\n' "$cmd" "$(command -v "$cmd")"
  else
    printf '%s: missing\n' "$cmd"
  fi
done
REMOTE
