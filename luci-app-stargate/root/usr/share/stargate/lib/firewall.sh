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

firewall_managed_ifaces() {
  {
    firewall_lan_ifaces
    [ "${netbird_proxy:-1}" != "1" ] || printf '%s\n' "${netbird_interface:-wt0}"
  } | awk 'NF && !seen[$0]++'
}

firewall_dns_ipv6_address() {
  # Prefer the stable LAN ULA over a delegated prefix that may be renumbered.
  firewall_lan_ifaces | while read -r iface; do
    ip -6 addr show dev "$iface" scope global 2>/dev/null | awk '/inet6 / { split($2, addr, "/"); print addr[1] }'
  done | awk '/^f[cd]/ { print; found=1; exit } !first { first=$0 } END { if (!found && first) print first }'
}

firewall_lan_ipv6_status() {
  dhcpv6="$(uci -q get dhcp.lan.dhcpv6 2>/dev/null || true)"
  ra="$(uci -q get dhcp.lan.ra 2>/dev/null || true)"
  ra_default="$(uci -q get dhcp.lan.ra_default 2>/dev/null || true)"
  dns="$(uci -q get dhcp.lan.dns 2>/dev/null || true)"
  printf 'dhcpv6=%s ra=%s ra_default=%s dns=%s' "${dhcpv6:-unset}" "${ra:-unset}" "${ra_default:-unset}" "${dns:-unset}"
}

firewall_apply_lan_ipv6_policy() {
  [ "$lan_ipv6_policy" = "disable_on_transparent" ] || return 0
  [ "$transparent_proxy" = "1" ] || return 0
  command -v uci >/dev/null 2>&1 || {
    echo "uci is required to apply LAN IPv6 policy" >&2
    return 1
  }

  mkdir -p "$work_dir"
  stamp="$(date +%Y%m%d-%H%M%S)"
  [ -f /etc/config/dhcp ] && cp -a /etc/config/dhcp "$work_dir/dhcp.before-lan-ipv6-$stamp.bak"
  [ -f /etc/config/network ] && cp -a /etc/config/network "$work_dir/network.before-lan-ipv6-$stamp.bak"

  uci set dhcp.lan.dhcpv6='disabled'
  uci set dhcp.lan.ra='disabled'
  uci set dhcp.lan.ra_default='0'
  uci -q delete dhcp.lan.dns || true
  uci commit dhcp
  [ -x /etc/init.d/odhcpd ] && /etc/init.d/odhcpd restart >/dev/null 2>&1 || true
  [ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
  echo "LAN IPv6 DHCP/RA disabled for Stargate transparent proxy"
}

firewall_clean_iptables() {
  command -v iptables >/dev/null 2>&1 || return 0
  iptables -t nat -S PREROUTING 2>/dev/null | grep 'STARGATE_' | sed 's/^-A /-D /' | while read -r rule; do
    iptables -t nat $rule 2>/dev/null || true
  done
  iptables -S FORWARD 2>/dev/null | grep 'STARGATE_' | sed 's/^-A /-D /' | while read -r rule; do
    iptables $rule 2>/dev/null || true
  done
  iptables -S INPUT 2>/dev/null | grep 'STARGATE_' | sed 's/^-A /-D /' | while read -r rule; do
    iptables $rule 2>/dev/null || true
  done
  iptables -t nat -F STARGATE_DNS 2>/dev/null || true
  iptables -t nat -X STARGATE_DNS 2>/dev/null || true
  iptables -t nat -F STARGATE_TCP 2>/dev/null || true
  iptables -t nat -X STARGATE_TCP 2>/dev/null || true
  iptables -F STARGATE_INPUT 2>/dev/null || true
  iptables -X STARGATE_INPUT 2>/dev/null || true
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

firewall_clean_ip6tables_dns() {
  command -v ip6tables >/dev/null 2>&1 || return 0
  ip6tables -t nat -S PREROUTING 2>/dev/null | grep 'STARGATE_DNS6' | sed 's/^-A /-D /' | while read -r rule; do
    ip6tables -t nat $rule 2>/dev/null || true
  done
  ip6tables -t nat -F STARGATE_DNS6 2>/dev/null || true
  ip6tables -t nat -X STARGATE_DNS6 2>/dev/null || true
}

firewall_apply_ip6tables_dns() {
  [ "$dns_hijack" = "1" ] || return 0
  [ -n "$dns_ipv6_address" ] || return 0
  command -v ip6tables >/dev/null 2>&1 && ip6tables -t nat -S >/dev/null 2>&1 || {
    echo "IPv6 DNS redirect requires ip6tables IPv6 NAT support" >&2
    return 1
  }
  ip6tables -t nat -N STARGATE_DNS6 || return 1
  if [ "$netbird_proxy" = "1" ]; then
    for cidr in fc00::/7 fe80::/10; do
      ip6tables -t nat -A STARGATE_DNS6 -i "$netbird_interface" -d "$cidr" -m addrtype ! --dst-type LOCAL -j RETURN || return 1
    done
  fi
  ip6tables -t nat -A STARGATE_DNS6 -p udp --dport 53 -j DNAT --to-destination "[$dns_ipv6_address]:$dns_hijack_port" || return 1
  ip6tables -t nat -A STARGATE_DNS6 -p tcp --dport 53 -j DNAT --to-destination "[$dns_ipv6_address]:$dns_hijack_port" || return 1
  firewall_managed_ifaces | while read -r iface; do
    ip6tables -t nat -I PREROUTING 1 -i "$iface" -p udp --dport 53 -j STARGATE_DNS6 || exit 1
    ip6tables -t nat -I PREROUTING 1 -i "$iface" -p tcp --dport 53 -j STARGATE_DNS6 || exit 1
  done
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
  firewall_clean_ip6tables_dns
  firewall_apply_ip6tables_dns || return 1
  iptables -t nat -N STARGATE_DNS
  iptables -t nat -N STARGATE_TCP
  if [ "$rules_block_quic" = "1" ]; then
    iptables -N STARGATE_QUIC
    if [ "$netbird_proxy" = "1" ]; then
      for cidr in 10.0.0.0/8 100.64.0.0/10 172.16.0.0/12 192.168.0.0/16; do
        iptables -A STARGATE_QUIC -i "$netbird_interface" -d "$cidr" -j RETURN
      done
      iptables -A STARGATE_QUIC -o "$netbird_interface" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    fi
    iptables -A STARGATE_QUIC -p udp --dport 443 -j REJECT
  fi
  input_guard=0
  if firewall_setup_transparent_input_guard; then
    input_guard=1
  fi

  if [ "$netbird_proxy" = "1" ]; then
    for cidr in 10.0.0.0/8 100.64.0.0/10 172.16.0.0/12 192.168.0.0/16; do
      iptables -t nat -A STARGATE_DNS -i "$netbird_interface" -d "$cidr" -m addrtype ! --dst-type LOCAL -j RETURN
    done
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

  firewall_managed_ifaces | while read -r iface; do
    [ -n "$iface" ] || continue
    iptables -t nat -I PREROUTING 1 -i "$iface" -p tcp -j STARGATE_TCP
    if [ "$dns_hijack" = "1" ]; then
      iptables -t nat -I PREROUTING 1 -i "$iface" -p udp --dport 53 -j STARGATE_DNS
      iptables -t nat -I PREROUTING 1 -i "$iface" -p tcp --dport 53 -j STARGATE_DNS
    fi
    if [ "$rules_block_quic" = "1" ]; then
      iptables -I FORWARD 1 -i "$iface" -p udp --dport 443 -j STARGATE_QUIC
    fi
    if [ "$input_guard" = "1" ]; then
      iptables -I INPUT 1 -i "$iface" -p tcp --dport "$transparent_port" -j STARGATE_INPUT
    fi
  done
  firewall_apply_ip6tables_guard
}

firewall_lan_ipv4_addrs() {
  {
    firewall_lan_ifaces | while read -r iface; do
      [ -n "$iface" ] || continue
      ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / { split($2, addr, "/"); print addr[1] }'
    done
    uci -q get network.lan.ipaddr 2>/dev/null || true
  } | awk -F. '
    NF == 4 {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) next
      }
      if (!seen[$0]++) print
    }
  '
}

firewall_setup_transparent_input_guard() {
  iptables -m conntrack -h >/dev/null 2>&1 || return 1
  lan_addrs="$(firewall_lan_ipv4_addrs)"
  [ -n "$lan_addrs" ] || return 1
  iptables -N STARGATE_INPUT || return 1
  printf '%s\n' "$lan_addrs" | while read -r lan_addr; do
    [ -n "$lan_addr" ] || continue
    iptables -A STARGATE_INPUT -p tcp --dport "$transparent_port" -m conntrack --ctorigdst "$lan_addr" --ctorigdstport "$transparent_port" -j REJECT || exit 1
  done
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
    # Public CIDRs must reach sing-box: their domain may have a proxy override.
    # This set only protects local/reserved destinations, in every routing mode.
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
  firewall_managed_ifaces | while read -r iface; do
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

  iface_set="$(firewall_managed_ifaces | awk 'BEGIN{first=1}{gsub(/"/,"\\\""); if(!first) printf ", "; printf "\"%s\"", $0; first=0}')"
  [ -n "$iface_set" ] || iface_set='"br-lan"'
  direct_ip_set="$(firewall_direct_bypass_cidrs all | awk 'BEGIN{first=1}{ if(!first) printf ", "; printf "%s", $0; first=0 }')"
  direct_set_block=""
  direct_ip_return=""
  if [ -n "$direct_ip_set" ]; then
    direct_set_block="  set direct4 {
    type ipv4_addr
    flags interval
    auto-merge
    elements = { $direct_ip_set }
  }
"
    direct_ip_return="    iifname { $iface_set } ip daddr @direct4 counter return comment \"Stargate direct bypass\""
  fi
  # Delete and recreate in one transaction, only after the complete batch validates.
  replace_table=""
  if nft list table inet stargate >/dev/null 2>&1; then
    replace_table="delete table inet stargate"
  fi
  tmp_nft="$(mktemp "$tmp_prefix-nft.XXXXXX")"
  cat >"$tmp_nft" <<EOF
$replace_table
table inet stargate {
$direct_set_block
  chain prerouting {
    type nat hook prerouting priority dstnat - 10; policy accept;
    iifname "$netbird_interface" ip daddr { 10.0.0.0/8, 100.64.0.0/10, 172.16.0.0/12, 192.168.0.0/16 } fib daddr type != local counter return comment "Stargate overlay private bypass"
    iifname "$netbird_interface" ip6 daddr { fc00::/7, fe80::/10 } fib daddr type != local counter return comment "Stargate overlay private bypass"
    iifname { $iface_set } meta nfproto ipv4 udp dport 53 counter redirect to :$dns_hijack_port comment "Stargate DNS redirect"
    iifname { $iface_set } meta nfproto ipv4 tcp dport 53 counter redirect to :$dns_hijack_port comment "Stargate DNS redirect"
    iifname { $iface_set } meta nfproto ipv6 udp dport 53 counter dnat ip6 to [$dns_ipv6_address]:$dns_hijack_port comment "Stargate DNS redirect"
    iifname { $iface_set } meta nfproto ipv6 tcp dport 53 counter dnat ip6 to [$dns_ipv6_address]:$dns_hijack_port comment "Stargate DNS redirect"
$direct_ip_return
    iifname { $iface_set } meta nfproto ipv4 meta l4proto tcp counter redirect to :$transparent_port comment "Stargate transparent redirect"
  }
  # After all DNAT hooks: the kernel may share NAT hook registration across
  # tables, so a filter between NAT priorities can still see the old address.
  # NetBird only inserts
  # external INPUT/FORWARD accepts, so it cannot bypass this guard.
  chain guard {
    type filter hook prerouting priority filter - 10; policy accept;
    ct direction reply counter return comment "Stargate reply bypass"
    iifname { $iface_set } meta nfproto ipv4 tcp dport $transparent_port ct status dnat counter return comment "Stargate transparent redirected input"
    iifname { $iface_set } meta nfproto ipv4 tcp dport $transparent_port counter reject comment "Stargate transparent input guard"
    fib daddr type local counter return comment "Stargate local input"
    iifname "$netbird_interface" ip daddr { 10.0.0.0/8, 100.64.0.0/10, 172.16.0.0/12, 192.168.0.0/16 } counter return comment "Stargate overlay private bypass"
    iifname { $iface_set } ip6 daddr { ::1/128, fc00::/7, fe80::/10, ff00::/8 } counter return comment "Stargate local IPv6"
    iifname { $iface_set } meta nfproto ipv6 counter reject comment "Stargate IPv6 guard"
    iifname { $iface_set } udp dport 443 counter reject comment "Stargate QUIC block"
  }
}
EOF
  if [ "$dns_hijack" != "1" ]; then
    sed -i '/dport 53/d' "$tmp_nft"
  fi
  if [ -z "$dns_ipv6_address" ]; then
    sed -i '/dnat ip6 to/d' "$tmp_nft"
  fi
  if [ "$netbird_proxy" != "1" ]; then
    sed -i '/Stargate overlay .* bypass/d' "$tmp_nft"
  fi
  if [ "$rules_block_quic" != "1" ]; then
    sed -i '/Stargate QUIC block/d' "$tmp_nft"
  fi
  rc=0
  if nft -c -f "$tmp_nft"; then
    nft -f "$tmp_nft" || rc=$?
  else
    rc=$?
  fi
  rm -f "$tmp_nft"
  return "$rc"
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
    nft) firewall_apply_nft || return $? ;;
    iptables) firewall_apply_iptables || return $? ;;
    *) echo "no supported firewall backend found" >&2; return 1 ;;
  esac
  firewall_apply_lan_ipv6_policy || return $?
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
  firewall_clean_ip6tables_dns
  echo "firewall cleaned"
}

firewall_nft_rule_packets() {
  marker="$1"
  nft list table inet stargate 2>/dev/null | awk -v marker="$marker" '
    index($0, "comment \"" marker "\"") {
      for (i = 1; i <= NF; i++) {
        if ($i == "packets" && $(i + 1) ~ /^[0-9]+$/) total += $(i + 1)
      }
    }
    END { printf "%.0f", total + 0 }
  '
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
  elif command -v nft >/dev/null 2>&1 && nft list table inet stargate 2>/dev/null | grep -Eq 'meta nfproto ipv6 reject|reject with icmpv6'; then
    ipv6_guard="yes"
  fi
  printf 'Backend: %s\n' "$backend"
  printf 'Active: %s\n' "$active"
  printf 'LAN interfaces: %s\n' "$(firewall_lan_ifaces | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  printf 'Managed interfaces: %s\n' "$(firewall_managed_ifaces | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  printf 'NetBird proxy: %s (%s)\n' "$netbird_proxy" "$netbird_interface"
  printf 'Transparent: %s %s:%s\n' "$transparent_proxy" "$transparent_mode" "$transparent_port"
  printf 'DNS redirect: %s:%s\n' "$dns_hijack" "$dns_hijack_port"
  printf 'QUIC block: %s\n' "$rules_block_quic"
  printf 'IPv6 guard: %s\n' "$ipv6_guard"
  printf 'LAN IPv6 policy: %s\n' "$lan_ipv6_policy"
  printf 'LAN IPv6 state: %s\n' "$(firewall_lan_ipv6_status)"
  if conflict="$(firewall_conflicting_proxy)"; then
    printf 'Proxy conflict: %s\n' "$conflict"
  else
    printf 'Proxy conflict: no\n'
  fi
  if [ "$backend" = "nft" ] && [ "$active" = "yes" ]; then
    printf 'Rule packets: DNS=%s transparent=%s direct-bypass=%s\n' \
      "$(firewall_nft_rule_packets "Stargate DNS redirect")" \
      "$(firewall_nft_rule_packets "Stargate transparent redirect")" \
      "$(firewall_nft_rule_packets "Stargate direct bypass")"
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
  elif command -v nft >/dev/null 2>&1 && nft list table inet stargate 2>/dev/null | grep -Eq 'meta nfproto ipv6 reject|reject with icmpv6'; then
    ipv6_guard=true
  fi
  lan_ifaces="$(firewall_lan_ifaces | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if conflict="$(firewall_conflicting_proxy)"; then
    proxy_conflict="$conflict"
  else
    proxy_conflict="no"
  fi
  lan_ipv6_state="$(firewall_lan_ipv6_status)"
  dns_packets=0
  transparent_packets=0
  direct_bypass_packets=0
  if [ "$backend" = "nft" ] && [ "$active" = "true" ]; then
    dns_packets="$(firewall_nft_rule_packets "Stargate DNS redirect")"
    transparent_packets="$(firewall_nft_rule_packets "Stargate transparent redirect")"
    direct_bypass_packets="$(firewall_nft_rule_packets "Stargate direct bypass")"
  fi
  managed_ifaces="$(firewall_managed_ifaces | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  message="Backend: $backend; Active: $active; LAN interfaces: $lan_ifaces; Managed interfaces: $managed_ifaces; NetBird proxy: $netbird_proxy ($netbird_interface); Transparent: $transparent_proxy $transparent_mode:$transparent_port; DNS redirect: $dns_hijack:$dns_hijack_port; Rule packets: DNS=$dns_packets transparent=$transparent_packets direct-bypass=$direct_bypass_packets; QUIC block: $rules_block_quic; IPv6 guard: $ipv6_guard; LAN IPv6 policy: $lan_ipv6_policy; LAN IPv6 state: $lan_ipv6_state; Proxy conflict: $proxy_conflict"
  printf '{"backend":"%s","active":%s,"ipv6_guard":%s,"lan_ipv6_policy":"%s","dns_packets":%s,"transparent_packets":%s,"direct_bypass_packets":%s,"proxy_conflict":"%s","message":"%s"}' "$backend" "$active" "$ipv6_guard" "$(printf '%s' "$lan_ipv6_policy" | json_escape)" "$dns_packets" "$transparent_packets" "$direct_bypass_packets" "$(printf '%s' "$proxy_conflict" | json_escape)" "$(printf '%s' "$message" | json_escape)"
}
