# shellcheck shell=sh
json_escape() {
  sed 's/\\/\\\\/g; s/"/\\"/g'
}

bool_json() {
  case "${1:-0}" in
    1|true|TRUE|yes|on) printf true ;;
    *) printf false ;;
  esac
}

bool_value() {
  case "${1:-0}" in
    1|true|TRUE|yes|on) printf 1 ;;
    *) printf 0 ;;
  esac
}

validate_port_value() {
  value="$1"
  label="$2"
  case "$value" in
    ''|*[!0-9]*)
      echo "$label must be numeric" >&2
      return 1
      ;;
  esac
  [ "$value" -gt 0 ] && [ "$value" -le 65535 ] || {
    echo "$label must be between 1 and 65535" >&2
    return 1
  }
}

validate_listen_address() {
  value="$1"
  label="$2"
  case "$value" in
    '')
      echo "$label is required" >&2
      return 1
      ;;
    *[!0-9A-Fa-f:.]*)
      echo "$label must be an IPv4 or IPv6 address" >&2
      return 1
      ;;
    *:*)
      # IPv6: hex groups and colons only, at most one "::".
      case "$value" in
        *:::*|*::*::*)
          echo "$label must be an IPv4 or IPv6 address" >&2
          return 1
          ;;
      esac
      return 0
      ;;
    *)
      old_ifs="$IFS"
      IFS=.
      # shellcheck disable=SC2086
      set -- $value
      IFS="$old_ifs"
      [ "$#" -eq 4 ] || {
        echo "$label must be an IPv4 or IPv6 address" >&2
        return 1
      }
      for octet in "$@"; do
        case "$octet" in
          ''|*[!0-9]*)
            echo "$label must be an IPv4 or IPv6 address" >&2
            return 1
            ;;
        esac
        [ "$octet" -le 255 ] || {
          echo "$label must be an IPv4 or IPv6 address" >&2
          return 1
        }
      done
      return 0
      ;;
  esac
}

# Print one named node_item section id per line. Anonymous sections and ids
# that are not safe as shell identifiers or sing-box tags are skipped.
list_node_item_ids() {
  if [ -n "${UCI_CONFIG_DIR:-}" ]; then
    node_raw="$(uci -q -c "$UCI_CONFIG_DIR" show "$app" 2>/dev/null || true)"
  else
    node_raw="$(uci -q show "$app" 2>/dev/null || true)"
  fi
  printf '%s\n' "$node_raw" | sed -n "s/^$app\\.\\([^.=]*\\)=node_item$/\\1/p" | while IFS= read -r node_id; do
    case "$node_id" in
      ''|*[!A-Za-z0-9_]*) continue ;;
    esac
    printf '%s\n' "$node_id"
  done
}

uci_get() {
  if [ -n "${UCI_CONFIG_DIR:-}" ]; then
    uci -q -c "$UCI_CONFIG_DIR" get "$app.$1.$2" 2>/dev/null || printf '%s' "$3"
  else
    uci -q get "$app.$1.$2" 2>/dev/null || printf '%s' "$3"
  fi
}

uci_cmd() {
  if [ -n "${UCI_CONFIG_DIR:-}" ]; then
    uci -q -c "$UCI_CONFIG_DIR" "$@"
  else
    uci -q "$@"
  fi
}

uci_commit() {
  if [ -n "${UCI_CONFIG_DIR:-}" ]; then
    uci -q -c "$UCI_CONFIG_DIR" commit "$app"
  else
    uci -q commit "$app"
  fi
}

load_config() {
  work_dir="$(uci_get global work_dir "$work_dir")"
  config_file="$(uci_get global config_file "$config_file")"
  next_file="$config_file.next"
  backup_file="$config_file.bak"
  singbox_bin="$(uci_get global singbox_bin "$singbox_bin")"

  auto_start="$(bool_value "$(uci_get global auto_start 0)")"
  log_level="$(uci_get global log_level warn)"
  socks_listen="$(uci_get inbound socks_listen 127.0.0.1)"
  socks_port="$(uci_get inbound socks_port 10808)"
  http_listen="$(uci_get inbound http_listen 127.0.0.1)"
  http_port="$(uci_get inbound http_port 10809)"
  transparent_proxy="$(uci_get inbound transparent_proxy '')"
  if [ -z "$transparent_proxy" ]; then
    transparent_proxy="$(uci_get safety transparent_proxy 0)"
  fi
  transparent_proxy="$(bool_value "$transparent_proxy")"
  transparent_mode="$(uci_get inbound transparent_mode redirect)"
  transparent_listen="$(uci_get inbound transparent_listen 0.0.0.0)"
  transparent_port="$(uci_get inbound transparent_port 12345)"
  netbird_proxy="$(bool_value "$(uci_get inbound netbird_proxy 1)")"
  netbird_interface="$(uci_get inbound netbird_interface wt0)"

  node_type="$(uci_get node type anytls)"
  node_server="$(uci_get node server '')"
  node_port="$(uci_get node server_port 443)"
  node_password="$(uci_get node password '')"
  node_sni="$(uci_get node sni '')"
  node_insecure="$(uci_get node insecure 1)"

  # Dedicated-port nodes: aux_node_ids only holds node_item sections with
  # enable_port=1. A node identical to the active node reuses anytls-out
  # instead of opening a second session pool to the same server.
  aux_node_ids=""
  for aux_id in $(list_node_item_ids); do
    aux_enable="$(bool_value "$(uci_get "$aux_id" enable_port 0)")"
    [ "$aux_enable" = "1" ] || continue
    aux_node_ids="$aux_node_ids $aux_id"
    aux_server="$(uci_get "$aux_id" server '')"
    aux_port="$(uci_get "$aux_id" server_port 443)"
    aux_password="$(uci_get "$aux_id" password '')"
    aux_outbound="out-node-$aux_id"
    if [ "$aux_server" = "$node_server" ] && [ "$aux_port" = "$node_port" ] && [ "$aux_password" = "$node_password" ]; then
      aux_outbound="anytls-out"
    fi
    eval "aux_enable_port_$aux_id=\"\$aux_enable\""
    eval "aux_label_$aux_id=\"\$(uci_get \"\$aux_id\" label \"\$aux_id\")\""
    eval "aux_server_$aux_id=\"\$aux_server\""
    eval "aux_port_$aux_id=\"\$aux_port\""
    eval "aux_password_$aux_id=\"\$aux_password\""
    eval "aux_sni_$aux_id=\"\$(uci_get \"\$aux_id\" sni '')\""
    eval "aux_insecure_$aux_id=\"\$(uci_get \"\$aux_id\" insecure 1)\""
    eval "aux_socks_port_$aux_id=\"\$(uci_get \"\$aux_id\" socks_port '')\""
    eval "aux_http_port_$aux_id=\"\$(uci_get \"\$aux_id\" http_port '')\""
    eval "aux_listen_$aux_id=\"\$(uci_get \"\$aux_id\" listen 0.0.0.0)\""
    eval "aux_outbound_$aux_id=\"\$aux_outbound\""
  done

  dns_mode="$(uci_get dns mode tcp_doh)"
  dns_final="$(uci_get dns final direct-dns)"
  dns_strategy="$(uci_get dns strategy prefer_ipv4)"
  dns_local_preset="$(uci_get dns local_preset alidns_tcp)"
  dns_local_server="$(uci_get dns local_server 223.5.5.5)"
  dns_local_type="$(uci_get dns local_type tcp)"
  dns_local_path="$(uci_get dns local_path /dns-query)"
  dns_remote_preset="$(uci_get dns remote_preset google_doh)"
  dns_remote_server="$(uci_get dns remote_server dns.google)"
  dns_remote_type="$(uci_get dns remote_type https)"
  dns_remote_path="$(uci_get dns remote_path /dns-query)"
  dns_remote_detour="$(uci_get dns remote_detour anytls-out)"
  dns_hijack="$(bool_value "$(uci_get dns hijack_dns 1)")"
  dns_hijack_port="$(uci_get dns hijack_port 1053)"
  dns_lan_port="$(uci -q get 'dhcp.@dnsmasq[0].port' 2>/dev/null || true)"
  dns_lan_port="${dns_lan_port:-53}"
  dns_ipv6_address="$(firewall_dns_ipv6_address)"

  rules_mode="$(uci_get rules mode blacklist)"
  # Resolver fallback follows the routing mode; old dns.final values are ignored.
  case "$rules_mode" in
    whitelist|global_proxy) dns_final=remote-doh ;;
    *) dns_final=direct-dns ;;
  esac
  rules_default_outbound="direct"
  rules_source="$(uci_get rules source loyalsoldier)"
  rules_source_base_url="$(uci_get rules source_base_url https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release)"
  rules_geoip_base_url="$(uci_get rules geoip_base_url https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip)"
  rules_direct_rule_set="$(uci_get rules direct_rule_set /usr/share/stargate/rules/direct.json)"
  rules_proxy_rule_set="$(uci_get rules proxy_rule_set /usr/share/stargate/rules/proxy.json)"
  rules_geoip_direct_rule_set="$(uci_get rules geoip_direct_rule_set /usr/share/stargate/rules/geoip-cn.srs)"
  rules_geoip_proxy_rule_sets="$(uci_get rules geoip_proxy_rule_sets '/usr/share/stargate/rules/geoip-google.srs /usr/share/stargate/rules/geoip-facebook.srs /usr/share/stargate/rules/geoip-twitter.srs /usr/share/stargate/rules/geoip-telegram.srs')"
  rules_geoip_proxy_extra_cidrs="$(uci_get rules geoip_proxy_extra_cidrs '104.244.43.0/24 175.41.128.0/18')"
  rules_custom_direct_domains="$(uci_get rules custom_direct_domains '')"
  rules_custom_proxy_domains="$(uci_get rules custom_proxy_domains '')"
  rules_custom_direct_ips="$(uci_get rules custom_direct_ips '')"
  rules_custom_proxy_ips="$(uci_get rules custom_proxy_ips '')"
  rules_private_direct="$(uci_get rules private_direct 1)"
  rules_block_quic="$(uci_get rules block_quic 1)"
  backup_on_apply="$(uci_get safety backup_on_apply 1)"
  allow_proxy_conflict="$(bool_value "$(uci_get safety allow_proxy_conflict 0)")"
  lan_ipv6_policy="$(uci_get safety lan_ipv6_policy keep)"
}

validate_config() {
  [ "$node_type" = "anytls" ] || {
    echo "only anytls node is supported in this version" >&2
    exit 1
  }
  [ -n "$node_server" ] || {
    echo "active node is required: add a node and choose Use this node before generating or starting Stargate" >&2
    exit 1
  }
  [ -n "$node_password" ] || {
    echo "active node password is required: edit the node or choose another node" >&2
    exit 1
  }
  apply_dns_presets
  case "$dns_final" in remote-doh|direct-dns|local) ;; *) echo "unsupported final resolver: $dns_final" >&2; exit 1 ;; esac
  case "$dns_local_type" in tcp|udp|tls|https) ;; *) echo "unsupported local dns type: $dns_local_type" >&2; exit 1 ;; esac
  case "$dns_remote_type" in https|tls|tcp|udp) ;; *) echo "unsupported remote dns type: $dns_remote_type" >&2; exit 1 ;; esac
  validate_port_value "$dns_hijack_port" "DNS hijack port" || exit 1
  validate_port_value "$dns_lan_port" "dnsmasq port (local DNS is required)" || exit 1
  [ "$dns_hijack_port" != "$dns_lan_port" ] || {
    echo "DNS hijack port must differ from dnsmasq port" >&2
    return 1
  }
  if [ "$transparent_proxy" = "1" ] && [ "$dns_hijack" = "1" ] &&
     [ -s /proc/net/if_inet6 ] && [ -z "$dns_ipv6_address" ]; then
    echo "IPv6 DNS redirect requires a global-scope LAN address (ULA preferred); retry after LAN is ready" >&2
    return 1
  fi
  case "$rules_mode" in blacklist|whitelist|global_proxy|direct) ;; *) echo "unsupported rules mode: $rules_mode" >&2; exit 1 ;; esac
  case "$transparent_mode" in redirect|tproxy) ;; *) echo "unsupported transparent mode: $transparent_mode" >&2; exit 1 ;; esac
  if [ "$transparent_proxy" = "1" ] && [ "$transparent_mode" != "redirect" ]; then
    echo "transparent forwarding currently supports redirect mode only" >&2
    return 1
  fi
  case "$netbird_interface" in
    ''|*[!a-zA-Z0-9_.-]*) echo "invalid NetBird interface name" >&2; return 1 ;;
  esac
  [ "${#netbird_interface}" -le 15 ] || { echo "NetBird interface name is too long" >&2; return 1; }
  case "$lan_ipv6_policy" in keep|disable_on_transparent) ;; *) echo "unsupported LAN IPv6 policy: $lan_ipv6_policy" >&2; exit 1 ;; esac
  validate_port_value "$socks_port" "SOCKS port" || exit 1
  validate_port_value "$http_port" "HTTP port" || exit 1
  validate_port_value "$transparent_port" "transparent proxy port" || exit 1

  used_ports="$socks_port $http_port"
  if [ "$transparent_proxy" = "1" ]; then
    used_ports="$used_ports $transparent_port"
    if [ "$dns_hijack" = "1" ]; then
      used_ports="$used_ports $dns_hijack_port"
    fi
  fi

  if [ -n "${aux_node_ids:-}" ]; then
    for aux_id in $aux_node_ids; do
      eval "aux_server=\${aux_server_$aux_id:-}"
      eval "aux_port=\${aux_port_$aux_id:-443}"
      eval "aux_password=\${aux_password_$aux_id:-}"
      eval "aux_socks=\${aux_socks_port_$aux_id:-}"
      eval "aux_http=\${aux_http_port_$aux_id:-}"
      eval "aux_listen=\${aux_listen_$aux_id:-0.0.0.0}"
      [ -n "$aux_server" ] || { echo "node server is required for dedicated port node $aux_id" >&2; exit 1; }
      [ -n "$aux_password" ] || { echo "node password is required for dedicated port node $aux_id" >&2; exit 1; }
      validate_port_value "$aux_port" "node server port ($aux_id)" || exit 1
      validate_listen_address "$aux_listen" "dedicated listen address ($aux_id)" || exit 1
      if [ -z "$aux_socks" ] && [ -z "$aux_http" ]; then
        echo "at least one port (SOCKS or HTTP) is required for dedicated port node $aux_id" >&2
        exit 1
      fi
      if [ -n "$aux_socks" ]; then
        validate_port_value "$aux_socks" "auxiliary SOCKS port ($aux_id)" || exit 1
        for p in $used_ports; do
          if [ "$p" = "$aux_socks" ]; then
            echo "dedicated SOCKS port $aux_socks of node $aux_id conflicts with another Stargate port" >&2
            exit 1
          fi
        done
        used_ports="$used_ports $aux_socks"
      fi
      if [ -n "$aux_http" ]; then
        validate_port_value "$aux_http" "auxiliary HTTP port ($aux_id)" || exit 1
        for p in $used_ports; do
          if [ "$p" = "$aux_http" ]; then
            echo "dedicated HTTP port $aux_http of node $aux_id conflicts with another Stargate port" >&2
            exit 1
          fi
        done
        used_ports="$used_ports $aux_http"
      fi
    done
  fi
  if [ "$rules_mode" = "blacklist" ] || [ "$rules_mode" = "whitelist" ]; then
    direct_runtime_rule_set="$(rule_set_runtime_path "$rules_direct_rule_set")"
    proxy_runtime_rule_set="$(rule_set_runtime_path "$rules_proxy_rule_set")"
    [ -f "$rules_direct_rule_set" ] || {
      echo "direct rule-set missing: run Rules -> Update base rules first ($rules_direct_rule_set)" >&2
      exit 1
    }
    [ -f "$rules_proxy_rule_set" ] || {
      echo "proxy rule-set missing: run Rules -> Update base rules first ($rules_proxy_rule_set)" >&2
      exit 1
    }
    [ -f "$direct_runtime_rule_set" ] || {
      echo "compiled direct rule-set missing: run Rules -> Update base rules first ($direct_runtime_rule_set)" >&2
      exit 1
    }
    [ -f "$proxy_runtime_rule_set" ] || {
      echo "compiled proxy rule-set missing: run Rules -> Update base rules first ($proxy_runtime_rule_set)" >&2
      exit 1
    }
    if [ -n "$rules_geoip_direct_rule_set" ]; then
      [ -f "$rules_geoip_direct_rule_set" ] || {
        echo "GeoIP direct rule-set missing: run Rules -> Update base rules first ($rules_geoip_direct_rule_set)" >&2
        exit 1
      }
    fi
    printf '%s\n' "$rules_geoip_proxy_rule_sets" | tr ', \t' '\n\n\n' | while IFS= read -r geoip_rule_set; do
      [ -n "$geoip_rule_set" ] || continue
      [ -f "$geoip_rule_set" ] || {
        echo "GeoIP proxy rule-set missing: run Rules -> Update base rules first ($geoip_rule_set)" >&2
        exit 1
      }
    done
  fi
}

rule_set_runtime_path() {
  case "$1" in
    *.json) printf '%s.srs' "${1%.json}" ;;
    *) printf '%s' "$1" ;;
  esac
}

rule_set_runtime_format() {
  case "$1" in
    *.json) printf binary ;;
    *.srs) printf binary ;;
    *) printf source ;;
  esac
}

apply_dns_presets() {
  case "$dns_local_preset" in
    alidns_tcp)
      dns_local_type="tcp"
      dns_local_server="223.5.5.5"
      dns_local_path="/dns-query"
      ;;
    dnspod_tcp)
      dns_local_type="tcp"
      dns_local_server="119.29.29.29"
      dns_local_path="/dns-query"
      ;;
    onedns_tcp)
      dns_local_type="tcp"
      dns_local_server="114.114.114.114"
      dns_local_path="/dns-query"
      ;;
    custom) ;;
    *) echo "unsupported direct dns preset: $dns_local_preset" >&2; exit 1 ;;
  esac

  case "$dns_remote_preset" in
    cloudflare_doh)
      dns_remote_type="https"
      dns_remote_server="1.1.1.1"
      dns_remote_path="/dns-query"
      ;;
    cloudflare_security_doh)
      dns_remote_type="https"
      dns_remote_server="1.1.1.2"
      dns_remote_path="/dns-query"
      ;;
    google_doh)
      dns_remote_type="https"
      dns_remote_server="dns.google"
      dns_remote_path="/dns-query"
      ;;
    quad9_doh)
      dns_remote_type="https"
      dns_remote_server="9.9.9.9"
      dns_remote_path="/dns-query"
      ;;
    custom) ;;
    *) echo "unsupported remote dns preset: $dns_remote_preset" >&2; exit 1 ;;
  esac
}

uri_decode() {
  raw="$1"
  if command -v lua >/dev/null 2>&1; then
    lua - "$raw" <<'LUA'
local s = arg[1] or ""
s = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
io.write(s)
LUA
  else
    printf '%s' "$raw"
  fi
}

query_value() {
  query="$1"
  key="$2"
  printf '%s' "$query" | tr '&' '\n' | sed -n "s/^$key=//p" | tail -n 1
}

split_host_port() {
  hp="$1"
  default_port="$2"
  case "$hp" in
    \[*\]:*)
      host="${hp#\[}"
      host="${host%%\]*}"
      port="${hp##*:}"
      ;;
    *:*)
      host="${hp%:*}"
      port="${hp##*:}"
      ;;
    *)
      host="$hp"
      port="$default_port"
      ;;
  esac
}
