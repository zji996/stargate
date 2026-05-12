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

  node_type="$(uci_get node type anytls)"
  node_server="$(uci_get node server '')"
  node_port="$(uci_get node server_port 443)"
  node_password="$(uci_get node password '')"
  node_sni="$(uci_get node sni '')"
  node_insecure="$(uci_get node insecure 1)"

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

  rules_mode="$(uci_get rules mode blacklist)"
  rules_default_outbound="direct"
  rules_source="$(uci_get rules source loyalsoldier)"
  rules_source_base_url="$(uci_get rules source_base_url https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release)"
  rules_geoip_base_url="$(uci_get rules geoip_base_url https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip)"
  rules_direct_rule_set="$(uci_get rules direct_rule_set /usr/share/stargate/rules/direct.json)"
  rules_proxy_rule_set="$(uci_get rules proxy_rule_set /usr/share/stargate/rules/proxy.json)"
  rules_geoip_direct_rule_set="$(uci_get rules geoip_direct_rule_set /usr/share/stargate/rules/geoip-cn.srs)"
  rules_geoip_proxy_rule_sets="$(uci_get rules geoip_proxy_rule_sets '/usr/share/stargate/rules/geoip-google.srs /usr/share/stargate/rules/geoip-facebook.srs /usr/share/stargate/rules/geoip-twitter.srs /usr/share/stargate/rules/geoip-telegram.srs')"
  rules_geoip_proxy_extra_cidrs="$(uci_get rules geoip_proxy_extra_cidrs '104.244.43.0/24')"
  rules_custom_direct_domains="$(uci_get rules custom_direct_domains '')"
  rules_custom_proxy_domains="$(uci_get rules custom_proxy_domains '')"
  rules_custom_direct_ips="$(uci_get rules custom_direct_ips '')"
  rules_custom_proxy_ips="$(uci_get rules custom_proxy_ips '')"
  rules_private_direct="$(uci_get rules private_direct 1)"
  rules_block_quic="$(uci_get rules block_quic 1)"
  backup_on_apply="$(uci_get safety backup_on_apply 1)"
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
  case "$dns_hijack_port" in ''|*[!0-9]*) echo "DNS hijack port must be numeric" >&2; exit 1 ;; esac
  [ "$dns_hijack_port" -gt 0 ] && [ "$dns_hijack_port" -le 65535 ] || { echo "DNS hijack port must be between 1 and 65535" >&2; exit 1; }
  case "$rules_mode" in blacklist|whitelist|global_proxy|direct) ;; *) echo "unsupported rules mode: $rules_mode" >&2; exit 1 ;; esac
  case "$transparent_mode" in redirect|tproxy) ;; *) echo "unsupported transparent mode: $transparent_mode" >&2; exit 1 ;; esac
  case "$socks_port" in ''|*[!0-9]*) echo "SOCKS port must be numeric" >&2; exit 1 ;; esac
  case "$http_port" in ''|*[!0-9]*) echo "HTTP port must be numeric" >&2; exit 1 ;; esac
  case "$transparent_port" in ''|*[!0-9]*) echo "transparent proxy port must be numeric" >&2; exit 1 ;; esac
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
s = s:gsub("+", " ")
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
