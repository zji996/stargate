# shellcheck shell=sh
firewall_lan_ifaces() {
  ifaces="$(uci -q get network.lan.device 2>/dev/null || true)"
  if [ -z "$ifaces" ] && [ "$(uci -q get network.lan.type 2>/dev/null || true)" = "bridge" ] && ip link show br-lan >/dev/null 2>&1; then
    ifaces="br-lan"
  fi
  [ -n "$ifaces" ] || ifaces="$(uci -q get network.lan.ifname 2>/dev/null || true)"
  [ -n "$ifaces" ] || ifaces="br-lan"
  printf '%s\n' $ifaces
}

firewall_clean_iptables() {
  command -v iptables >/dev/null 2>&1 || return 0
  iptables -t nat -S PREROUTING 2>/dev/null | grep 'STARGATE_' | sed 's/^-A /-D /' | while read -r rule; do
    iptables -t nat $rule 2>/dev/null || true
  done
  iptables -S FORWARD 2>/dev/null | grep 'STARGATE_' | sed 's/^-A /-D /' | while read -r rule; do
    iptables $rule 2>/dev/null || true
  done
  iptables -t nat -F STARGATE_DNS 2>/dev/null || true
  iptables -t nat -X STARGATE_DNS 2>/dev/null || true
  iptables -t nat -F STARGATE_TCP 2>/dev/null || true
  iptables -t nat -X STARGATE_TCP 2>/dev/null || true
  iptables -F STARGATE_QUIC 2>/dev/null || true
  iptables -X STARGATE_QUIC 2>/dev/null || true
  command -v ipset >/dev/null 2>&1 && ipset destroy STARGATE_DIRECT4 2>/dev/null || true
}

firewall_clean_ip6tables() {
  command -v ip6tables >/dev/null 2>&1 || return 0
  ip6tables -S FORWARD 2>/dev/null | grep 'STARGATE_' | sed 's/^-A /-D /' | while read -r rule; do
    ip6tables $rule 2>/dev/null || true
  done
  ip6tables -F STARGATE_IPV6 2>/dev/null || true
  ip6tables -X STARGATE_IPV6 2>/dev/null || true
}

firewall_apply_iptables() {
  command -v iptables >/dev/null 2>&1 || {
    echo "iptables is required for this firewall backend" >&2
    return 1
  }
  [ "$transparent_mode" = "redirect" ] || {
    echo "iptables backend currently supports redirect mode only" >&2
    return 1
  }

  firewall_clean_iptables
  iptables -t nat -N STARGATE_DNS
  iptables -t nat -N STARGATE_TCP
  if [ "$rules_block_quic" = "1" ]; then
    iptables -N STARGATE_QUIC
    iptables -A STARGATE_QUIC -p udp --dport 443 -j REJECT
  fi

  iptables -t nat -A STARGATE_DNS -p udp --dport 53 -j REDIRECT --to-ports "$dns_hijack_port"
  iptables -t nat -A STARGATE_DNS -p tcp --dport 53 -j REDIRECT --to-ports "$dns_hijack_port"

  if firewall_setup_direct_ipset; then
    iptables -t nat -A STARGATE_TCP -m set --match-set STARGATE_DIRECT4 dst -j RETURN
  else
    firewall_direct_bypass_cidrs basic | while read -r cidr; do
      [ -n "$cidr" ] || continue
      iptables -t nat -A STARGATE_TCP -d "$cidr" -j RETURN
    done
  fi
  iptables -t nat -A STARGATE_TCP -p tcp -j REDIRECT --to-ports "$transparent_port"

  firewall_lan_ifaces | while read -r iface; do
    [ -n "$iface" ] || continue
    iptables -t nat -I PREROUTING 1 -i "$iface" -p tcp -j STARGATE_TCP
    if [ "$dns_hijack" = "1" ]; then
      iptables -t nat -I PREROUTING 1 -i "$iface" -p udp --dport 53 -j STARGATE_DNS
      iptables -t nat -I PREROUTING 1 -i "$iface" -p tcp --dport 53 -j STARGATE_DNS
    fi
    if [ "$rules_block_quic" = "1" ]; then
      iptables -I FORWARD 1 -i "$iface" -p udp --dport 443 -j STARGATE_QUIC
    fi
  done
  firewall_apply_ip6tables_guard
}

rule_set_ipv4_cidrs() {
  file="$1"
  [ -f "$file" ] || return 0
  awk '
    function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
    function valid_ip(ip, parts, i, n) {
      n = split(ip, parts, ".")
      if (n != 4) return 0
      for (i = 1; i <= 4; i++) {
        if (parts[i] !~ /^[0-9]+$/ || parts[i] < 0 || parts[i] > 255) return 0
      }
      return 1
    }
    /"ip_cidr"[[:space:]]*:/ {
      in_array = 1
      sub(/.*"ip_cidr"[[:space:]]*:[[:space:]]*\[/, "")
    }
    in_array {
      line = $0
      if (line ~ /\]/) {
        sub(/\].*/, "", line)
        in_array = 0
      }
      while (match(line, /"[^"]+"/)) {
        value = substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
        split(value, cidr, "/")
        prefix = cidr[2]
        if (prefix == "") prefix = 32
        if (valid_ip(cidr[1]) && prefix ~ /^[0-9]+$/ && prefix >= 0 && prefix <= 32) {
          value = cidr[1] "/" prefix
          if (!seen[value]++) print value
        }
      }
    }
  ' "$file"
}

firewall_direct_bypass_cidrs() {
  mode="${1:-all}"
  {
    for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
      printf '%s\n' "$cidr"
    done
    parse_ipv4_cidrs "$rules_custom_direct_ips"
    if [ "$mode" = "all" ]; then
      rule_set_ipv4_cidrs "$rules_direct_rule_set"
    fi
  } | awk '!seen[$0]++'
}

firewall_setup_direct_ipset() {
  command -v ipset >/dev/null 2>&1 || return 1
  iptables -m set -h >/dev/null 2>&1 || return 1
  {
    printf 'create STARGATE_DIRECT4 hash:net family inet maxelem 65536 -exist\n'
    printf 'flush STARGATE_DIRECT4\n'
    firewall_direct_bypass_cidrs all | awk '{ printf "add STARGATE_DIRECT4 %s -exist\n", $0 }'
  } | ipset restore -exist >/dev/null 2>&1
}

firewall_apply_ip6tables_guard() {
  command -v ip6tables >/dev/null 2>&1 || return 0
  firewall_clean_ip6tables
  ip6tables -N STARGATE_IPV6
  for cidr in ::1/128 fc00::/7 fe80::/10 ff00::/8; do
    ip6tables -A STARGATE_IPV6 -d "$cidr" -j RETURN
  done
  ip6tables -A STARGATE_IPV6 -j REJECT
  firewall_lan_ifaces | while read -r iface; do
    [ -n "$iface" ] || continue
    ip6tables -I FORWARD 1 -i "$iface" -j STARGATE_IPV6
  done
}

firewall_clean_nft() {
  command -v nft >/dev/null 2>&1 || return 0
  nft delete table inet stargate 2>/dev/null || true
}

firewall_apply_nft() {
  command -v nft >/dev/null 2>&1 || {
    echo "nft is required for this firewall backend" >&2
    return 1
  }
  [ "$transparent_mode" = "redirect" ] || {
    echo "nft backend currently supports redirect mode only" >&2
    return 1
  }

  iface_set="$(firewall_lan_ifaces | awk 'BEGIN{first=1}{gsub(/"/,"\\\""); if(!first) printf ", "; printf "\"%s\"", $0; first=0}')"
  [ -n "$iface_set" ] || iface_set='"br-lan"'
  direct_ip_set="$(firewall_direct_bypass_cidrs all | awk 'BEGIN{first=1}{ if(!first) printf ", "; printf "%s", $0; first=0 }')"
  direct_ip_return=""
  if [ -n "$direct_ip_set" ]; then
    direct_ip_return="    iifname { $iface_set } meta nfproto ipv4 ip daddr { $direct_ip_set } return"
  fi
  firewall_clean_nft
  tmp_nft="$(mktemp "$tmp_prefix-nft.XXXXXX")"
  cat >"$tmp_nft" <<EOF
table inet stargate {
  chain prerouting {
    type nat hook prerouting priority dstnat - 2; policy accept;
    iifname { $iface_set } meta nfproto ipv4 udp dport 53 redirect to :$dns_hijack_port
    iifname { $iface_set } meta nfproto ipv4 tcp dport 53 redirect to :$dns_hijack_port
    iifname { $iface_set } meta nfproto ipv4 ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } return
$direct_ip_return
    iifname { $iface_set } meta nfproto ipv4 meta l4proto tcp redirect to :$transparent_port
  }
  chain forward {
    type filter hook forward priority filter - 2; policy accept;
    iifname { $iface_set } ip6 daddr { ::1/128, fc00::/7, fe80::/10, ff00::/8 } return
    iifname { $iface_set } meta nfproto ipv6 reject
    iifname { $iface_set } meta nfproto ipv4 udp dport 443 reject
  }
}
EOF
  if [ "$dns_hijack" != "1" ]; then
    sed -i '/dport 53/d' "$tmp_nft"
  fi
  if [ "$rules_block_quic" != "1" ]; then
    sed -i '/udp dport 443 reject/d' "$tmp_nft"
  fi
  nft -f "$tmp_nft"
  rm -f "$tmp_nft"
}

firewall_backend() {
  if command -v nft >/dev/null 2>&1; then
    printf nft
  elif command -v iptables >/dev/null 2>&1; then
    printf iptables
  else
    printf none
  fi
}

firewall_conflicting_proxy() {
  for svc in passwall2 passwall openclash; do
    [ -x "/etc/init.d/$svc" ] || continue
    if "/etc/init.d/$svc" enabled >/dev/null 2>&1; then
      printf '%s enabled' "$svc"
      return 0
    fi
  done
  if [ "$(uci -q get passwall2.@global[0].enabled 2>/dev/null || true)" = "1" ]; then
    printf 'passwall2 enabled'
    return 0
  fi
  if [ "$(uci -q get passwall.@global[0].enabled 2>/dev/null || true)" = "1" ]; then
    printf 'passwall enabled'
    return 0
  fi
  if [ "$(uci -q get openclash.config.enable 2>/dev/null || true)" = "1" ]; then
    printf 'openclash enabled'
    return 0
  fi
  if ps w 2>/dev/null | grep -E '/tmp/etc/passwall2|/usr/share/passwall2|/tmp/etc/passwall|/usr/share/passwall|openclash|mihomo|clash' | grep -v grep >/dev/null; then
    printf 'another proxy process running'
    return 0
  fi
  return 1
}

firewall_proxy_conflict_allowed() {
  [ "${STARGATE_ALLOW_PROXY_CONFLICT:-0}" = "1" ] || [ "${allow_proxy_conflict:-0}" = "1" ]
}

firewall_require_no_proxy_conflict() {
  firewall_proxy_conflict_allowed && return 0
  conflict="$(firewall_conflicting_proxy)" || return 0
  echo "refusing to apply Stargate transparent forwarding: $conflict; stop the other proxy first or set safety.allow_proxy_conflict=1 deliberately" >&2
  return 1
}

firewall_apply_rules() {
  load_config
  if [ "$transparent_proxy" != "1" ]; then
    firewall_clean
    echo "firewall cleaned; transparent proxy is disabled"
    return 0
  fi
  firewall_require_no_proxy_conflict || return 1
  validate_config
  backend="$(firewall_backend)"
  case "$backend" in
    nft) firewall_apply_nft ;;
    iptables) firewall_apply_iptables ;;
    *) echo "no supported firewall backend found" >&2; return 1 ;;
  esac
  echo "firewall applied with $backend"
}

firewall_apply() {
  load_config
  if [ "$transparent_proxy" != "1" ]; then
    firewall_clean
    echo "firewall cleaned; transparent proxy is disabled"
    return 0
  fi
  firewall_require_no_proxy_conflict || return 1
  validate_config
  apply_config
  restart_service_with_rollback
  firewall_apply_rules
}

firewall_clean() {
  firewall_clean_nft
  firewall_clean_iptables
  firewall_clean_ip6tables
  echo "firewall cleaned"
}

firewall_status_text() {
  load_config
  backend="$(firewall_backend)"
  active="no"
  if command -v nft >/dev/null 2>&1 && nft list table inet stargate >/dev/null 2>&1; then
    active="yes"
  fi
  if command -v iptables >/dev/null 2>&1 && iptables -t nat -S 2>/dev/null | grep -q 'STARGATE_'; then
    active="yes"
  fi
  ipv6_guard="no"
  if command -v ip6tables >/dev/null 2>&1 && ip6tables -S FORWARD 2>/dev/null | grep -q 'STARGATE_IPV6'; then
    ipv6_guard="yes"
  elif command -v nft >/dev/null 2>&1 && nft list table inet stargate 2>/dev/null | grep -q 'meta nfproto ipv6 reject'; then
    ipv6_guard="yes"
  fi
  printf 'Backend: %s\n' "$backend"
  printf 'Active: %s\n' "$active"
  printf 'LAN interfaces: %s\n' "$(firewall_lan_ifaces | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  printf 'Transparent: %s %s:%s\n' "$transparent_proxy" "$transparent_mode" "$transparent_port"
  printf 'DNS redirect: %s:%s\n' "$dns_hijack" "$dns_hijack_port"
  printf 'QUIC block: %s\n' "$rules_block_quic"
  printf 'IPv6 guard: %s\n' "$ipv6_guard"
  if conflict="$(firewall_conflicting_proxy)"; then
    printf 'Proxy conflict: %s\n' "$conflict"
  else
    printf 'Proxy conflict: no\n'
  fi
}

firewall_status_json() {
  backend="$(firewall_backend)"
  active=false
  if command -v nft >/dev/null 2>&1 && nft list table inet stargate >/dev/null 2>&1; then
    active=true
  fi
  if command -v iptables >/dev/null 2>&1 && iptables -t nat -S 2>/dev/null | grep -q 'STARGATE_'; then
    active=true
  fi
  ipv6_guard=false
  if command -v ip6tables >/dev/null 2>&1 && ip6tables -S FORWARD 2>/dev/null | grep -q 'STARGATE_IPV6'; then
    ipv6_guard=true
  elif command -v nft >/dev/null 2>&1 && nft list table inet stargate 2>/dev/null | grep -q 'meta nfproto ipv6 reject'; then
    ipv6_guard=true
  fi
  lan_ifaces="$(firewall_lan_ifaces | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if conflict="$(firewall_conflicting_proxy)"; then
    proxy_conflict="$conflict"
  else
    proxy_conflict="no"
  fi
  message="Backend: $backend; Active: $active; LAN interfaces: $lan_ifaces; Transparent: $transparent_proxy $transparent_mode:$transparent_port; DNS redirect: $dns_hijack:$dns_hijack_port; QUIC block: $rules_block_quic; IPv6 guard: $ipv6_guard; Proxy conflict: $proxy_conflict"
  printf '{"backend":"%s","active":%s,"ipv6_guard":%s,"proxy_conflict":"%s","message":"%s"}' "$backend" "$active" "$ipv6_guard" "$(printf '%s' "$proxy_conflict" | json_escape)" "$(printf '%s' "$message" | json_escape)"
}
