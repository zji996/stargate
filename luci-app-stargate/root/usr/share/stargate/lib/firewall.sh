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
  iptables -S FORWARD 2>/dev/null | grep 'STARGATE_QUIC' | sed 's/^-A /-D /' | while read -r rule; do
    iptables $rule 2>/dev/null || true
  done
  iptables -t nat -F STARGATE_DNS 2>/dev/null || true
  iptables -t nat -X STARGATE_DNS 2>/dev/null || true
  iptables -t nat -F STARGATE_TCP 2>/dev/null || true
  iptables -t nat -X STARGATE_TCP 2>/dev/null || true
  iptables -F STARGATE_QUIC 2>/dev/null || true
  iptables -X STARGATE_QUIC 2>/dev/null || true
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

  for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
    iptables -t nat -A STARGATE_TCP -d "$cidr" -j RETURN
  done
  parse_ipv4_cidrs "$rules_custom_direct_ips" | while read -r cidr; do
    [ -n "$cidr" ] || continue
    iptables -t nat -A STARGATE_TCP -d "$cidr" -j RETURN
  done
  iptables -t nat -A STARGATE_TCP -p tcp -j REDIRECT --to-ports "$transparent_port"

  firewall_lan_ifaces | while read -r iface; do
    [ -n "$iface" ] || continue
    if [ "$dns_hijack" = "1" ]; then
      iptables -t nat -A PREROUTING -i "$iface" -p udp --dport 53 -j STARGATE_DNS
      iptables -t nat -A PREROUTING -i "$iface" -p tcp --dport 53 -j STARGATE_DNS
    fi
    if [ "$rules_block_quic" = "1" ]; then
      iptables -A FORWARD -i "$iface" -p udp --dport 443 -j STARGATE_QUIC
    fi
    iptables -t nat -A PREROUTING -i "$iface" -p tcp -j STARGATE_TCP
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
  direct_ip_set="$(parse_ipv4_cidrs "$rules_custom_direct_ips" | awk 'BEGIN{first=1}{ if(!first) printf ", "; printf "%s", $0; first=0 }')"
  direct_ip_return=""
  if [ -n "$direct_ip_set" ]; then
    direct_ip_return="    iifname { $iface_set } ip daddr { $direct_ip_set } return"
  fi
  firewall_clean_nft
  tmp_nft="$(mktemp "$tmp_prefix-nft.XXXXXX")"
  cat >"$tmp_nft" <<EOF
table inet stargate {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname { $iface_set } udp dport 53 redirect to :$dns_hijack_port
    iifname { $iface_set } tcp dport 53 redirect to :$dns_hijack_port
    iifname { $iface_set } ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } return
$direct_ip_return
    iifname { $iface_set } tcp redirect to :$transparent_port
  }
  chain forward {
    type filter hook forward priority filter; policy accept;
    iifname { $iface_set } udp dport 443 reject
  }
}
EOF
  if [ "$dns_hijack" != "1" ]; then
    sed -i '/dport 53/d' "$tmp_nft"
  fi
  if [ "$rules_block_quic" != "1" ]; then
    sed -i '/chain forward {/,/}/d' "$tmp_nft"
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

firewall_apply_rules() {
  load_config
  if [ "$transparent_proxy" != "1" ]; then
    firewall_clean
    echo "firewall cleaned; transparent proxy is disabled"
    return 0
  fi
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
  validate_config
  apply_config
  restart_service_with_rollback
  firewall_apply_rules
}

firewall_clean() {
  firewall_clean_nft
  firewall_clean_iptables
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
  printf 'Backend: %s\n' "$backend"
  printf 'Active: %s\n' "$active"
  printf 'LAN interfaces: %s\n' "$(firewall_lan_ifaces | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  printf 'Transparent: %s %s:%s\n' "$transparent_proxy" "$transparent_mode" "$transparent_port"
  printf 'DNS redirect: %s:%s\n' "$dns_hijack" "$dns_hijack_port"
  printf 'QUIC block: %s\n' "$rules_block_quic"
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
  lan_ifaces="$(firewall_lan_ifaces | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  message="Backend: $backend; Active: $active; LAN interfaces: $lan_ifaces; Transparent: $transparent_proxy $transparent_mode:$transparent_port; DNS redirect: $dns_hijack:$dns_hijack_port; QUIC block: $rules_block_quic"
  printf '{"backend":"%s","active":%s,"message":"%s"}' "$backend" "$active" "$(printf '%s' "$message" | json_escape)"
}

