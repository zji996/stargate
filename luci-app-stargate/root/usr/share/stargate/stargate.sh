#!/bin/sh
set -eu

app="stargate"
work_dir="/etc/stargate"
config_file="$work_dir/config.json"
next_file="$config_file.next"
backup_file="$config_file.bak"
singbox_bin="/usr/bin/sing-box"
tmp_prefix="/tmp/stargate"

usage() {
  cat <<'USAGE'
Usage:
  /usr/share/stargate/stargate.sh generate
  /usr/share/stargate/stargate.sh check
  /usr/share/stargate/stargate.sh apply
  /usr/share/stargate/stargate.sh rollback
  /usr/share/stargate/stargate.sh start
  /usr/share/stargate/stargate.sh start-transparent [redirect|tproxy] [port]
  /usr/share/stargate/stargate.sh stop
  /usr/share/stargate/stargate.sh status
  /usr/share/stargate/stargate.sh firewall-apply
  /usr/share/stargate/stargate.sh firewall-clean
  /usr/share/stargate/stargate.sh firewall-status
  /usr/share/stargate/stargate.sh probe baidu|google|github
  /usr/share/stargate/stargate.sh node-add label server port password sni insecure
  /usr/share/stargate/stargate.sh node-add-link anytls://...
  /usr/share/stargate/stargate.sh node-update id label server port password sni insecure
  /usr/share/stargate/stargate.sh node-list
  /usr/share/stargate/stargate.sh node-use id
  /usr/share/stargate/stargate.sh node-delete id
  /usr/share/stargate/stargate.sh rules-update
  /usr/share/stargate/stargate.sh rules-update-start
  /usr/share/stargate/stargate.sh rules-status
  /usr/share/stargate/stargate.sh rules-test domain-or-ip
  /usr/share/stargate/stargate.sh backup-create [output.tar.gz]
  /usr/share/stargate/stargate.sh backup-restore input.tar.gz
  /usr/share/stargate/stargate.sh reset-defaults
  /usr/share/stargate/stargate.sh singbox-upgrade uploaded-binary
  /usr/share/stargate/stargate.sh singbox-rollback
  /usr/share/stargate/stargate.sh logs
  /usr/share/stargate/stargate.sh logs-raw
  /usr/share/stargate/stargate.sh logs-clear
USAGE
}

rules_update_pid_file="$tmp_prefix-rules-update.pid"
rules_update_status_file="$tmp_prefix-rules-update.status"
rules_update_log_file="$tmp_prefix-rules-update.log"

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
  dns_remote_preset="$(uci_get dns remote_preset quad9_doh)"
  dns_remote_server="$(uci_get dns remote_server 9.9.9.9)"
  dns_remote_type="$(uci_get dns remote_type https)"
  dns_remote_path="$(uci_get dns remote_path /dns-query)"
  dns_remote_detour="$(uci_get dns remote_detour anytls-out)"
  dns_hijack="$(bool_value "$(uci_get dns hijack_dns 1)")"
  dns_hijack_port="$(uci_get dns hijack_port 1053)"

  rules_mode="$(uci_get rules mode blacklist)"
  rules_default_outbound="direct"
  rules_source="$(uci_get rules source loyalsoldier)"
  rules_source_base_url="$(uci_get rules source_base_url https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release)"
  rules_direct_rule_set="$(uci_get rules direct_rule_set /usr/share/stargate/rules/direct.json)"
  rules_proxy_rule_set="$(uci_get rules proxy_rule_set /usr/share/stargate/rules/proxy.json)"
  rules_custom_direct_domains="$(uci_get rules custom_direct_domains '')"
  rules_custom_proxy_domains="$(uci_get rules custom_proxy_domains '')"
  rules_custom_direct_ips="$(uci_get rules custom_direct_ips '')"
  rules_custom_proxy_ips="$(uci_get rules custom_proxy_ips '')"
  rules_private_direct="$(uci_get rules private_direct 1)"
  rules_block_quic="$(uci_get rules block_quic 0)"
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
    [ -f "$rules_direct_rule_set" ] || {
      echo "direct rule-set missing: run Rules -> Update base rules first ($rules_direct_rule_set)" >&2
      exit 1
    }
    [ -f "$rules_proxy_rule_set" ] || {
      echo "proxy rule-set missing: run Rules -> Update base rules first ($rules_proxy_rule_set)" >&2
      exit 1
    }
  fi
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
      dns_remote_server="8.8.8.8"
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

new_node_id() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    id="$(cat /proc/sys/kernel/random/uuid | tr -d '-' | cut -c1-10)"
  else
    id="$(date +%s)"
  fi
  printf 'node_%s' "$id"
}

validate_node_fields() {
  [ "${node_type:-anytls}" = "anytls" ] || {
    echo "only anytls node is supported in this version" >&2
    exit 1
  }
  [ -n "${node_server:-}" ] || {
    echo "node server is required" >&2
    exit 1
  }
  [ -n "${node_password:-}" ] || {
    echo "node password is required" >&2
    exit 1
  }
  case "${node_port:-443}" in
    ''|*[!0-9]*) echo "node port must be numeric" >&2; exit 1 ;;
  esac
}

node_add_values() {
  node_label="${1:-}"
  node_server="${2:-}"
  node_port="${3:-443}"
  node_password="${4:-}"
  node_sni="${5:-}"
  node_insecure="${6:-1}"
  node_type="anytls"
  [ -n "$node_label" ] || node_label="$node_server"
  [ -n "$node_port" ] || node_port="443"
  case "$node_insecure" in 1|true|TRUE|yes|on) node_insecure="1" ;; *) node_insecure="0" ;; esac
  validate_node_fields

  id="$(new_node_id)"
  uci_cmd set "$app.$id=node_item"
  uci_cmd set "$app.$id.type=$node_type"
  uci_cmd set "$app.$id.label=$node_label"
  uci_cmd set "$app.$id.server=$node_server"
  uci_cmd set "$app.$id.server_port=$node_port"
  uci_cmd set "$app.$id.password=$node_password"
  uci_cmd set "$app.$id.sni=$node_sni"
  uci_cmd set "$app.$id.insecure=$node_insecure"
  uci_commit
  echo "node added: $node_label ($id)"
}

parse_anytls_link() {
  uri="$1"
  case "$uri" in
    anytls://*) ;;
    *) echo "only anytls:// link is supported in this version" >&2; exit 1 ;;
  esac

  rest="${uri#anytls://}"
  fragment=""
  case "$rest" in
    *#*)
      fragment="${rest#*#}"
      rest="${rest%%#*}"
      ;;
  esac
  query=""
  case "$rest" in
    *\?*)
      query="${rest#*\?}"
      rest="${rest%%\?*}"
      ;;
  esac
  userinfo=""
  hostport="${rest%%/*}"
  case "$rest" in
    *@*)
      userinfo="${rest%@*}"
      hostport="${rest#*@}"
      hostport="${hostport%%/*}"
      ;;
  esac

  split_host_port "$hostport" "443"
  node_type="anytls"
  node_label="$(uri_decode "$fragment")"
  node_server="$(uri_decode "$host")"
  node_port="$port"
  node_password="$(uri_decode "$userinfo")"
  node_sni="$(uri_decode "$(query_value "$query" sni)")"
  [ -n "$node_sni" ] || node_sni="$(uri_decode "$(query_value "$query" peer)")"
  node_insecure="$(query_value "$query" insecure)"
  [ -n "$node_insecure" ] || node_insecure="$(query_value "$query" allowInsecure)"
  [ -n "$node_insecure" ] || node_insecure="1"
  [ -n "$node_label" ] || node_label="$node_server"
}

node_add_link() {
  parse_anytls_link "${1:-}"
  node_add_values "$node_label" "$node_server" "$node_port" "$node_password" "$node_sni" "$node_insecure"
}

node_update() {
  id="${1:-}"
  case "$id" in ''|*[!A-Za-z0-9_-]*) echo "invalid node id" >&2; exit 1 ;; esac
  [ "$(uci_get "$id" type '')" = "anytls" ] || {
    echo "node not found or unsupported: $id" >&2
    exit 1
  }

  node_label="${2:-}"
  node_server="${3:-}"
  node_port="${4:-443}"
  node_password="${5:-}"
  node_sni="${6:-}"
  node_insecure="${7:-1}"
  node_type="anytls"
  [ -n "$node_label" ] || node_label="$node_server"
  [ -n "$node_port" ] || node_port="443"
  [ -n "$node_password" ] || node_password="$(uci_get "$id" password '')"
  case "$node_insecure" in 1|true|TRUE|yes|on) node_insecure="1" ;; *) node_insecure="0" ;; esac
  validate_node_fields

  uci_cmd set "$app.$id.type=anytls"
  uci_cmd set "$app.$id.label=$node_label"
  uci_cmd set "$app.$id.server=$node_server"
  uci_cmd set "$app.$id.server_port=$node_port"
  uci_cmd set "$app.$id.password=$node_password"
  uci_cmd set "$app.$id.sni=$node_sni"
  uci_cmd set "$app.$id.insecure=$node_insecure"
  uci_commit
  echo "node updated: $node_label"
}

node_list() {
  active_server="$(uci_get node server '')"
  active_port="$(uci_get node server_port '')"
  if [ -n "${UCI_CONFIG_DIR:-}" ]; then
    uci -q -c "$UCI_CONFIG_DIR" show "$app" 2>/dev/null
  else
    uci -q show "$app" 2>/dev/null
  fi | sed -n "s/^$app\\.\\([^.=]*\\)=node_item$/\\1/p" | while IFS= read -r id; do
    type="$(uci_get "$id" type anytls)"
    label="$(uci_get "$id" label "$id")"
    server="$(uci_get "$id" server '')"
    port="$(uci_get "$id" server_port 443)"
    sni="$(uci_get "$id" sni '')"
    insecure="$(uci_get "$id" insecure 1)"
    active=0
    if [ "$server" = "$active_server" ] && [ "$port" = "$active_port" ]; then
      active=1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$active" "$type" "$label" "$server" "$port" "$sni" "$insecure"
  done
}

node_use() {
  id="${1:-}"
  case "$id" in ''|*[!A-Za-z0-9_-]*) echo "invalid node id" >&2; exit 1 ;; esac
  [ "$(uci_get "$id" type '')" = "anytls" ] || {
    echo "node not found or unsupported: $id" >&2
    exit 1
  }
  node_label="$(uci_get "$id" label "$id")"
  node_server="$(uci_get "$id" server '')"
  node_port="$(uci_get "$id" server_port 443)"
  node_password="$(uci_get "$id" password '')"
  node_sni="$(uci_get "$id" sni '')"
  node_insecure="$(uci_get "$id" insecure 1)"
  node_type="anytls"
  validate_node_fields
  uci_cmd set "$app.node.type=anytls"
  uci_cmd set "$app.node.label=$node_label"
  uci_cmd set "$app.node.server=$node_server"
  uci_cmd set "$app.node.server_port=$node_port"
  uci_cmd set "$app.node.password=$node_password"
  uci_cmd set "$app.node.sni=$node_sni"
  uci_cmd set "$app.node.insecure=$node_insecure"
  uci_commit
  echo "active node: $node_label"
}

node_delete() {
  id="${1:-}"
  case "$id" in ''|*[!A-Za-z0-9_-]*) echo "invalid node id" >&2; exit 1 ;; esac
  [ "$(uci_get "$id" type '')" = "anytls" ] || {
    echo "node not found: $id" >&2
    exit 1
  }
  uci_cmd delete "$app.$id"
  uci_commit
  echo "node deleted: $id"
}

rules_status() {
  load_config
  direct_count="not updated"
  proxy_count="not updated"
  update_state="idle"
  update_last=""
  saved_state=""
  [ -s "$rules_update_status_file" ] && saved_state="$(cat "$rules_update_status_file" 2>/dev/null || true)"
  if [ -s "$rules_update_pid_file" ]; then
    update_pid="$(cat "$rules_update_pid_file" 2>/dev/null || true)"
    if [ "$saved_state" = "running" ] && [ -n "$update_pid" ] && kill -0 "$update_pid" 2>/dev/null; then
      update_state="running"
    elif [ -n "$saved_state" ]; then
      update_state="$saved_state"
    fi
  elif [ -n "$saved_state" ]; then
    update_state="$saved_state"
  fi
  if [ -s "$rules_update_log_file" ]; then
    update_last="$(awk '/^(Started|Finished) at / { line = $0 } END { print line }' "$rules_update_log_file" 2>/dev/null || true)"
  fi
  [ -f "$rules_direct_rule_set" ] && direct_count="$(grep -o '"' "$rules_direct_rule_set" 2>/dev/null | wc -l | awk '{print int($1 / 2)}') domains"
  [ -f "$rules_proxy_rule_set" ] && proxy_count="$(grep -o '"' "$rules_proxy_rule_set" 2>/dev/null | wc -l | awk '{print int($1 / 2)}') domains"
  printf 'Rule source: Loyalsoldier/v2ray-rules-dat\n'
  printf 'Rule update: %s\n' "$update_state"
  [ -z "$update_last" ] || printf 'Last update: %s\n' "$update_last"
  printf 'Direct list: %s\n' "$direct_count"
  printf 'Proxy list: %s\n' "$proxy_count"
}

normalize_rule_target() {
  printf '%s' "${1:-}" | awk '
    function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
    {
      v = trim($0)
      sub(/^[A-Za-z][A-Za-z0-9+.-]*:\/\//, "", v)
      if (index(v, "@") > 0) sub(/^.*@/, "", v)
      cut_pos = 0
      slash_pos = index(v, "/")
      query_pos = index(v, "?")
      hash_pos = index(v, "#")
      if (slash_pos > 0) cut_pos = slash_pos
      if (query_pos > 0 && (cut_pos == 0 || query_pos < cut_pos)) cut_pos = query_pos
      if (hash_pos > 0 && (cut_pos == 0 || hash_pos < cut_pos)) cut_pos = hash_pos
      if (cut_pos > 0) v = substr(v, 1, cut_pos - 1)
      if (substr(v, 1, 1) == "[") {
        close_pos = index(v, "]")
        if (close_pos > 1) v = substr(v, 2, close_pos - 2)
      } else if (v !~ /:.*:/) {
        sub(/:[0-9]+$/, "", v)
      }
      sub(/\.$/, "", v)
      print tolower(trim(v))
      exit
    }
  '
}

is_ipv4() {
  printf '%s\n' "$1" | awk -F. '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
      }
      exit 0
    }
  '
}

is_ip_address() {
  is_ipv4 "$1" || { printf '%s' "$1" | grep -q ':' && printf '%s' "$1" | grep -Eq '^[0-9a-f:]+$'; }
}

is_private_address() {
  target="$1"
  if is_ipv4 "$target"; then
    printf '%s\n' "$target" | awk -F. '
      $1 == 0 || $1 == 10 || $1 == 127 { exit 0 }
      $1 == 100 && $2 >= 64 && $2 <= 127 { exit 0 }
      $1 == 169 && $2 == 254 { exit 0 }
      $1 == 172 && $2 >= 16 && $2 <= 31 { exit 0 }
      $1 == 192 && $2 == 168 { exit 0 }
      $1 >= 224 { exit 0 }
      { exit 1 }
    '
    return "$?"
  fi
  case "$target" in
    ::1|fc*:*|fd*:*|fe80:*) return 0 ;;
    *) return 1 ;;
  esac
}

ipv4_to_int() {
  printf '%s\n' "$1" | awk -F. '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
      }
      printf "%.0f\n", ($1 * 16777216) + ($2 * 65536) + ($3 * 256) + $4
    }
  '
}

parse_ipv4_cidrs() {
  list="$1"
  printf '%s\n' "$list" | tr ', \t' '\n\n\n' | awk '
    function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
    function valid_ip(ip, parts, i, n) {
      n = split(ip, parts, ".")
      if (n != 4) return 0
      for (i = 1; i <= 4; i++) {
        if (parts[i] !~ /^[0-9]+$/ || parts[i] < 0 || parts[i] > 255) return 0
      }
      return 1
    }
    {
      line = trim($0)
      if (line == "" || line ~ /^#/) next
      sub(/^ip-cidr:/, "", line)
      split(line, cidr, "/")
      ip = cidr[1]
      prefix = cidr[2]
      if (prefix == "") prefix = 32
      if (!valid_ip(ip) || prefix !~ /^[0-9]+$/ || prefix < 0 || prefix > 32) next
      value = ip "/" prefix
      if (!seen[value]++) print value
    }
  '
}

custom_ip_match() {
  list="$1"
  target="$2"
  is_ipv4 "$target" || return 1
  target_int="$(ipv4_to_int "$target" 2>/dev/null)" || return 1
  parse_ipv4_cidrs "$list" | awk -F/ -v target_int="$target_int" '
    function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
    function ipint(ip, parts, i, n) {
      n = split(ip, parts, ".")
      if (n != 4) return -1
      for (i = 1; i <= 4; i++) {
        if (parts[i] !~ /^[0-9]+$/ || parts[i] < 0 || parts[i] > 255) return -1
      }
      return (parts[1] * 16777216) + (parts[2] * 65536) + (parts[3] * 256) + parts[4]
    }
    function pow2(n, r) { r = 1; while (n-- > 0) r *= 2; return r }
    {
      base = trim($1)
      prefix = $2
      base_int = ipint(base)
      if (base_int < 0) next
      size = pow2(32 - prefix)
      network = int(base_int / size) * size
      if (target_int >= network && target_int < network + size) {
        print base "/" prefix
        found = 1
        exit
      }
    }
    END { exit found ? 0 : 1 }
  '
}

custom_domain_match() {
  list="$1"
  target="$2"
  printf '%s\n' "$list" | awk -v target="$target" '
    function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
    function suffix_match(domain, suffix) {
      return domain == suffix || (length(domain) > length(suffix) && substr(domain, length(domain) - length(suffix), 1) == "." && substr(domain, length(domain) - length(suffix) + 1) == suffix)
    }
    {
      line = tolower(trim($0))
      if (line == "" || line ~ /^#/) next
      sub(/^full:/, "", line)
      sub(/^domain:/, "", line)
      sub(/^\+\./, "", line)
      if (line !~ /^[a-z0-9_.-]+$/) next
      if (suffix_match(target, line)) {
        print line
        found = 1
        exit
      }
    }
    END { exit found ? 0 : 1 }
  '
}

write_inline_ip_rule() {
  list="$1"
  outbound="$2"
  cidrs="$(parse_ipv4_cidrs "$list" | awk '{ if (count++) printf ", "; printf "\"%s\"", $0 }')"
  [ -n "$cidrs" ] || return 0
  printf '{ "ip_cidr": [%s], "outbound": "%s" }' "$cidrs" "$outbound"
}

rule_set_match() {
  file="$1"
  target="$2"
  [ -f "$file" ] || return 1
  candidate="$target"
  while [ -n "$candidate" ]; do
    if grep -Fq "\"$candidate\"" "$file"; then
      printf 'domain_suffix:%s\n' "$candidate"
      return 0
    fi
    case "$candidate" in
      *.*) candidate="${candidate#*.}" ;;
      *) break ;;
    esac
  done
  return 1
}

rules_test() {
  load_config
  target="$(normalize_rule_target "${1:-}")"
  [ -n "$target" ] || {
    echo "Target is required" >&2
    exit 1
  }
  printf 'Target: %s\n' "$target"

  if is_ip_address "$target"; then
    if [ "$rules_private_direct" = "1" ] && is_private_address "$target"; then
      printf 'Decision: Direct\n'
      printf 'Outbound: direct\n'
      printf 'Reason: private IP direct\n'
      return 0
    fi
    match="$(custom_ip_match "$rules_custom_direct_ips" "$target" 2>/dev/null || true)"
    if [ -n "$match" ]; then
      printf 'Decision: Direct\n'
      printf 'Outbound: direct\n'
      printf 'Reason: user direct IP (%s)\n' "$match"
      return 0
    fi
    match="$(custom_ip_match "$rules_custom_proxy_ips" "$target" 2>/dev/null || true)"
    if [ -n "$match" ]; then
      printf 'Decision: Proxy\n'
      printf 'Outbound: anytls-out\n'
      printf 'Reason: user proxy IP (%s)\n' "$match"
      return 0
    fi
    case "$rules_mode" in
      global_proxy)
        printf 'Decision: Proxy\n'
        printf 'Outbound: anytls-out\n'
        printf 'Reason: global proxy mode\n'
        ;;
      whitelist)
        printf 'Decision: Proxy\n'
        printf 'Outbound: anytls-out\n'
        printf 'Reason: whitelist default\n'
        ;;
      direct|blacklist|*)
        printf 'Decision: Direct\n'
        printf 'Outbound: direct\n'
        printf 'Reason: IP address default\n'
        ;;
    esac
    return 0
  fi

  case "$target" in *[!a-z0-9_.-]*|.*|*..*|*.) echo "Invalid domain or IP: $target" >&2; exit 1 ;; esac

  if [ "$rules_mode" = "global_proxy" ]; then
    printf 'Decision: Proxy\n'
    printf 'Outbound: anytls-out\n'
    printf 'Reason: global proxy mode\n'
    return 0
  fi
  if [ "$rules_mode" = "direct" ]; then
    printf 'Decision: Direct\n'
    printf 'Outbound: direct\n'
    printf 'Reason: direct only mode\n'
    return 0
  fi

  match="$(custom_domain_match "$rules_custom_direct_domains" "$target" 2>/dev/null || true)"
  if [ -n "$match" ]; then
    printf 'Decision: Direct\n'
    printf 'Outbound: direct\n'
    printf 'Reason: user direct domain (%s)\n' "$match"
    return 0
  fi

  match="$(custom_domain_match "$rules_custom_proxy_domains" "$target" 2>/dev/null || true)"
  if [ -n "$match" ]; then
    printf 'Decision: Proxy\n'
    printf 'Outbound: anytls-out\n'
    printf 'Reason: user proxy domain (%s)\n' "$match"
    return 0
  fi

  match="$(rule_set_match "$rules_direct_rule_set" "$target" 2>/dev/null || true)"
  if [ -n "$match" ]; then
    printf 'Decision: Direct\n'
    printf 'Outbound: direct\n'
    printf 'Reason: direct rule-set (%s)\n' "$match"
    return 0
  fi

  match="$(rule_set_match "$rules_proxy_rule_set" "$target" 2>/dev/null || true)"
  if [ -n "$match" ]; then
    printf 'Decision: Proxy\n'
    printf 'Outbound: anytls-out\n'
    printf 'Reason: proxy rule-set (%s)\n' "$match"
    return 0
  fi

  if [ "$rules_mode" = "whitelist" ]; then
    printf 'Decision: Proxy\n'
    printf 'Outbound: anytls-out\n'
    printf 'Reason: whitelist default\n'
  else
    printf 'Decision: Direct\n'
    printf 'Outbound: direct\n'
    printf 'Reason: blacklist default\n'
  fi
}

json_array_from_list() {
  key="$1"
  file="$2"
  awk -v key="$key" '
    function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
    function emit(v) {
      gsub(/\\/,"\\\\",v)
      gsub(/"/,"\\\"",v)
      if (count > 0) printf ","
      printf "\"%s\"", v
      count++
    }
    {
      line = trim($0)
      if (line == "" || line ~ /^#/) next
      if (line ~ /^regexp:/) next
      if (line ~ /^full:/) {
        if (key == "domain") emit(substr(line, 6))
        next
      }
      if (line ~ /^domain:/) {
        if (key == "domain_suffix") emit(substr(line, 8))
        next
      }
      if (line ~ /^keyword:/) {
        if (key == "domain_keyword") emit(substr(line, 9))
        next
      }
      if (line !~ /^[A-Za-z0-9_.-]+$/) next
      if (key == "domain_suffix") emit(line)
    }
  ' "$file"
}

write_rule_set_json() {
  input="$1"
  output="$2"
  tmp="$output.tmp"
  mkdir -p "$(dirname "$output")"
  {
    printf '{\n  "version": 3,\n  "rules": [\n'
    printf '    {\n      "domain": ['
    json_array_from_list domain "$input"
    printf '],\n      "domain_suffix": ['
    json_array_from_list domain_suffix "$input"
    printf '],\n      "domain_keyword": ['
    json_array_from_list domain_keyword "$input"
    printf ']\n    }\n'
    printf '  ]\n}\n'
  } >"$tmp"
  mv "$tmp" "$output"
}

fetch_rule_list() {
  url="$1"
  output="$2"
  attempt=1
  while [ "$attempt" -le 3 ]; do
    if curl -fsSL --connect-timeout 8 --max-time 180 "$url" -o "$output"; then
      return 0
    fi
    rm -f "$output"
    attempt=$((attempt + 1))
    sleep 2
  done
  return 1
}

rules_update() {
  load_config
  [ "$rules_source" = "loyalsoldier" ] || {
    echo "unsupported rules source: $rules_source" >&2
    exit 1
  }
  command -v curl >/dev/null 2>&1 || {
    echo "curl is required to update rules" >&2
    exit 1
  }

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
  base="${rules_source_base_url%/}"
  fetch_rule_list "$base/direct-list.txt" "$tmp_dir/direct-list.txt"
  fetch_rule_list "$base/proxy-list.txt" "$tmp_dir/proxy-list.txt"
  [ -s "$tmp_dir/direct-list.txt" ] || { echo "downloaded direct list is empty" >&2; exit 1; }
  [ -s "$tmp_dir/proxy-list.txt" ] || { echo "downloaded proxy list is empty" >&2; exit 1; }
  write_rule_set_json "$tmp_dir/direct-list.txt" "$rules_direct_rule_set"
  write_rule_set_json "$tmp_dir/proxy-list.txt" "$rules_proxy_rule_set"
  echo "Rules updated."
  rules_status
}

rules_update_start() {
  if [ -s "$rules_update_pid_file" ]; then
    update_pid="$(cat "$rules_update_pid_file" 2>/dev/null || true)"
    update_state="$(cat "$rules_update_status_file" 2>/dev/null || true)"
    if [ "$update_state" = "running" ] && [ -n "$update_pid" ] && kill -0 "$update_pid" 2>/dev/null; then
      echo "Rule update is already running."
      rules_status
      return 0
    fi
  fi

  rm -f "$rules_update_pid_file"
  printf 'running\n' >"$rules_update_status_file"
  {
    printf 'Started at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$rules_update_log_file"

  (
    trap '' HUP
    if "$0" rules-update >>"$rules_update_log_file" 2>&1; then
      printf 'Finished at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$rules_update_log_file"
      printf 'success\n' >"$rules_update_status_file"
    else
      code="$?"
      printf 'Finished at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$rules_update_log_file"
      printf 'failed (%s)\n' "$code" >"$rules_update_status_file"
    fi
    rm -f "$rules_update_pid_file"
  ) </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" >"$rules_update_pid_file"

  echo "Rule update started."
  rules_status
}

write_inline_domain_rule() {
  list="$1"
  outbound="$2"
  domains="$(printf '%s\n' "$list" | awk '
    function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
    function emit(v) {
      gsub(/\\/,"\\\\",v)
      gsub(/"/,"\\\"",v)
      if (count > 0) printf ","
      printf "\"%s\"", v
      count++
    }
    {
      line = trim($0)
      if (line == "" || line ~ /^#/) next
      if (line ~ /^full:/) line = substr(line, 6)
      else if (line ~ /^domain:/) line = substr(line, 8)
      else if (line ~ /^\+\./) line = substr(line, 3)
      if (line !~ /^[A-Za-z0-9_.-]+$/) next
      emit(line)
    }
  ')"
  [ -n "$domains" ] || return 0
  printf '{ "domain_suffix": [%s], "outbound": "%s" }' "$domains" "$outbound"
}

write_dns_servers() {
  esc_local="$(printf '%s' "$dns_local_server" | json_escape)"
  esc_local_path="$(printf '%s' "$dns_local_path" | json_escape)"
  esc_remote="$(printf '%s' "$dns_remote_server" | json_escape)"
  esc_path="$(printf '%s' "$dns_remote_path" | json_escape)"
  esc_detour="$(printf '%s' "$dns_remote_detour" | json_escape)"

  printf '      { "tag": "local", "type": "local" },\n'
  if [ "$dns_local_type" = "https" ]; then
    printf '      { "tag": "direct-dns", "type": "https", "server": "%s", "path": "%s" },\n' "$esc_local" "$esc_local_path"
  else
    printf '      { "tag": "direct-dns", "type": "%s", "server": "%s" },\n' "$dns_local_type" "$esc_local"
  fi
  if [ "$dns_remote_type" = "https" ]; then
    printf '      { "tag": "remote-doh", "type": "https", "server": "%s", "path": "%s", "detour": "%s" }\n' "$esc_remote" "$esc_path" "$esc_detour"
  else
    printf '      { "tag": "remote-doh", "type": "%s", "server": "%s", "detour": "%s" }\n' "$dns_remote_type" "$esc_remote" "$esc_detour"
  fi
}

write_dns_rules() {
  if [ "$rules_mode" = "blacklist" ] || [ "$rules_mode" = "whitelist" ]; then
    printf '      { "rule_set": "direct", "server": "direct-dns" },\n'
    printf '      { "rule_set": "proxy", "server": "remote-doh" }\n'
  fi
}

write_inbounds() {
  printf '    {\n'
  printf '      "type": "socks",\n'
  printf '      "tag": "socks-in",\n'
  printf '      "listen": "%s",\n' "$esc_socks_listen"
  printf '      "listen_port": %s\n' "$socks_port"
  printf '    },\n'
  printf '    {\n'
  printf '      "type": "http",\n'
  printf '      "tag": "http-in",\n'
  printf '      "listen": "%s",\n' "$esc_http_listen"
  printf '      "listen_port": %s\n' "$http_port"
  printf '    }'
  if [ "$transparent_proxy" = "1" ]; then
    printf ',\n'
    printf '    {\n'
    printf '      "type": "%s",\n' "$transparent_mode"
    printf '      "tag": "transparent-in",\n'
    printf '      "listen": "%s",\n' "$esc_transparent_listen"
    printf '      "listen_port": %s' "$transparent_port"
    if [ "$transparent_mode" = "tproxy" ]; then
      printf ',\n      "network": "tcp"\n'
    else
      printf '\n'
    fi
    printf '    }'
    if [ "$dns_hijack" = "1" ]; then
      printf ',\n'
      printf '    {\n'
      printf '      "type": "direct",\n'
      printf '      "tag": "dns-in",\n'
      printf '      "listen": "0.0.0.0",\n'
      printf '      "listen_port": %s,\n' "$dns_hijack_port"
      printf '      "override_address": "1.0.0.1",\n'
      printf '      "override_port": 53\n'
      printf '    }'
    fi
  fi
  printf '\n'
}

write_rule_sets() {
  if [ "$rules_mode" = "blacklist" ] || [ "$rules_mode" = "whitelist" ]; then
    printf '      {\n'
    printf '        "type": "local",\n'
    printf '        "tag": "direct",\n'
    printf '        "format": "source",\n'
    printf '        "path": "%s"\n' "$esc_direct_rule_set"
    printf '      },\n'
    printf '      {\n'
    printf '        "type": "local",\n'
    printf '        "tag": "proxy",\n'
    printf '        "format": "source",\n'
    printf '        "path": "%s"\n' "$esc_proxy_rule_set"
    printf '      }\n'
  fi
}

write_route_rules() {
  first=1
  add_rule() {
    if [ "$first" = 1 ]; then
      first=0
    else
      printf ',\n'
    fi
    printf '      %s' "$1"
  }

  if [ "$transparent_proxy" = "1" ]; then
    add_rule '{ "inbound": ["transparent-in"], "action": "sniff" }'
    if [ "$dns_hijack" = "1" ]; then
      add_rule '{ "inbound": ["dns-in"], "action": "hijack-dns" }'
    fi
  fi
  if [ "$rules_block_quic" = "1" ]; then
    add_rule '{ "network": "udp", "port": 443, "action": "reject" }'
  fi
  if [ "$rules_private_direct" = "1" ]; then
    add_rule '{ "ip_is_private": true, "outbound": "direct" }'
  fi
  custom_direct_ip_rule="$(write_inline_ip_rule "$rules_custom_direct_ips" "direct")"
  custom_proxy_ip_rule="$(write_inline_ip_rule "$rules_custom_proxy_ips" "anytls-out")"
  [ -z "$custom_direct_ip_rule" ] || add_rule "$custom_direct_ip_rule"
  [ -z "$custom_proxy_ip_rule" ] || add_rule "$custom_proxy_ip_rule"
  if [ "$rules_mode" = "blacklist" ] || [ "$rules_mode" = "whitelist" ]; then
    custom_direct_rule="$(write_inline_domain_rule "$rules_custom_direct_domains" "direct")"
    custom_proxy_rule="$(write_inline_domain_rule "$rules_custom_proxy_domains" "anytls-out")"
    [ -z "$custom_direct_rule" ] || add_rule "$custom_direct_rule"
    [ -z "$custom_proxy_rule" ] || add_rule "$custom_proxy_rule"
    add_rule '{ "rule_set": "direct", "outbound": "direct" }'
    add_rule '{ "rule_set": "proxy", "outbound": "anytls-out" }'
    if [ "$rules_mode" = "blacklist" ]; then
      rules_default_outbound="direct"
    else
      rules_default_outbound="anytls-out"
    fi
  elif [ "$rules_mode" = "global_proxy" ]; then
    rules_default_outbound="anytls-out"
  elif [ "$rules_mode" = "direct" ]; then
    rules_default_outbound="direct"
  fi
  printf '\n'
}

generate_config() {
  load_config
  validate_config
  mkdir -p "$work_dir"

  esc_server="$(printf '%s' "$node_server" | json_escape)"
  esc_password="$(printf '%s' "$node_password" | json_escape)"
  esc_sni="$(printf '%s' "$node_sni" | json_escape)"
  esc_socks_listen="$(printf '%s' "$socks_listen" | json_escape)"
  esc_http_listen="$(printf '%s' "$http_listen" | json_escape)"
  esc_transparent_listen="$(printf '%s' "$transparent_listen" | json_escape)"
  esc_direct_rule_set="$(printf '%s' "$rules_direct_rule_set" | json_escape)"
  esc_proxy_rule_set="$(printf '%s' "$rules_proxy_rule_set" | json_escape)"
  tls_server_name=""
  if [ -n "$node_sni" ]; then
    tls_server_name=", \"server_name\": \"$esc_sni\""
  fi

  {
    cat <<EOF
{
  "log": {
    "level": "$log_level",
    "timestamp": true
  },
  "dns": {
    "servers": [
EOF
    write_dns_servers
    cat <<EOF
    ],
    "rules": [
EOF
    write_dns_rules
    cat <<EOF
    ],
    "final": "$dns_final",
    "strategy": "$dns_strategy",
    "independent_cache": true
  },
  "inbounds": [
EOF
    write_inbounds
    cat <<EOF
  ],
  "outbounds": [
    {
      "type": "anytls",
      "tag": "anytls-out",
      "server": "$esc_server",
      "server_port": $node_port,
      "password": "$esc_password",
      "idle_session_check_interval": "30s",
      "idle_session_timeout": "30s",
      "min_idle_session": 5,
      "tls": {
        "enabled": true,
        "insecure": $(bool_json "$node_insecure")$tls_server_name
      }
    },
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "default_domain_resolver": "direct-dns",
    "rule_set": [
EOF
    write_rule_sets
    cat <<EOF
    ],
    "rules": [
EOF
    write_route_rules
    cat <<EOF
    ],
    "final": "$rules_default_outbound"
  }
}
EOF
  } >"$next_file"
  echo "$next_file"
}

check_next() {
  [ -x "$singbox_bin" ] || {
    echo "sing-box not found: $singbox_bin" >&2
    exit 1
  }
  "$singbox_bin" check -c "$next_file"
}

apply_config() {
  generated="$(generate_config)"
  next_file="$generated"
  check_next
  if [ "$backup_on_apply" = "1" ] && [ -f "$config_file" ]; then
    cp -a "$config_file" "$backup_file"
  fi
  mv "$next_file" "$config_file"
  echo "config applied: $config_file"
}

restore_backup_config() {
  load_config
  [ -f "$backup_file" ] || {
    echo "no backup config found: $backup_file" >&2
    return 1
  }
  [ -x "$singbox_bin" ] || {
    echo "sing-box not found: $singbox_bin" >&2
    return 1
  }
  "$singbox_bin" check -c "$backup_file"
  if [ -f "$config_file" ]; then
    cp -a "$config_file" "$config_file.rollback_from"
  fi
  cp -a "$backup_file" "$config_file"
  echo "rolled back config: $backup_file -> $config_file"
}

rollback_config() {
  restore_backup_config
  if pgrep -af "sing-box run -c" 2>/dev/null | grep -F -- "$config_file" >/dev/null 2>&1; then
    /etc/init.d/stargate restart
    echo "service restarted with backup config"
  else
    echo "service is not running; backup config restored"
  fi
}

restart_service_with_rollback() {
  if /etc/init.d/stargate restart; then
    echo "service restarted"
    return 0
  fi

  echo "service restart failed; trying rollback" >&2
  restore_backup_config || return 1
  if /etc/init.d/stargate restart; then
    echo "rollback applied and service restarted"
    return 0
  fi

  echo "service restart still failed after rollback" >&2
  return 1
}

ensure_inbound_section() {
  uci_cmd get "$app.inbound" >/dev/null 2>&1 || uci_cmd set "$app.inbound=inbound"
}

save_transparent_uci() {
  old_transparent_proxy="$(uci_get inbound transparent_proxy '')"
  old_transparent_mode="$(uci_get inbound transparent_mode '')"
  old_transparent_listen="$(uci_get inbound transparent_listen '')"
  old_transparent_port="$(uci_get inbound transparent_port '')"
}

restore_transparent_uci() {
  ensure_inbound_section
  if [ -n "${old_transparent_proxy:-}" ]; then
    uci_cmd set "$app.inbound.transparent_proxy=$old_transparent_proxy"
  else
    uci_cmd delete "$app.inbound.transparent_proxy" 2>/dev/null || true
  fi
  if [ -n "${old_transparent_mode:-}" ]; then
    uci_cmd set "$app.inbound.transparent_mode=$old_transparent_mode"
  else
    uci_cmd delete "$app.inbound.transparent_mode" 2>/dev/null || true
  fi
  if [ -n "${old_transparent_listen:-}" ]; then
    uci_cmd set "$app.inbound.transparent_listen=$old_transparent_listen"
  else
    uci_cmd delete "$app.inbound.transparent_listen" 2>/dev/null || true
  fi
  if [ -n "${old_transparent_port:-}" ]; then
    uci_cmd set "$app.inbound.transparent_port=$old_transparent_port"
  else
    uci_cmd delete "$app.inbound.transparent_port" 2>/dev/null || true
  fi
  uci_commit
}

start_local_proxy() {
  load_config
  transparent_proxy=0
  validate_config
  save_transparent_uci
  ensure_inbound_section
  uci_cmd set "$app.inbound.transparent_proxy=0"
  uci_commit
  if apply_config && restart_service_with_rollback; then
    firewall_clean >/dev/null 2>&1 || true
    echo "started local proxy mode"
  else
    rc=$?
    restore_transparent_uci
    exit "$rc"
  fi
}

start_transparent_proxy() {
  mode="${1:-redirect}"
  case "$mode" in redirect|tproxy) ;; *) echo "unsupported transparent mode: $mode" >&2; exit 1 ;; esac
  port="${2:-}"
  [ -n "$port" ] || port="$(uci_get inbound transparent_port 12345)"
  case "$port" in ''|*[!0-9]*) echo "transparent proxy port must be numeric" >&2; exit 1 ;; esac
  load_config
  transparent_proxy=1
  transparent_mode="$mode"
  transparent_port="$port"
  validate_config
  save_transparent_uci
  ensure_inbound_section
  uci_cmd set "$app.inbound.transparent_proxy=1"
  uci_cmd set "$app.inbound.transparent_mode=$mode"
  uci_cmd set "$app.inbound.transparent_listen=$(uci_get inbound transparent_listen 0.0.0.0)"
  uci_cmd set "$app.inbound.transparent_port=$port"
  uci_commit
  if apply_config && restart_service_with_rollback && firewall_apply_rules; then
    echo "started transparent proxy mode: $mode"
  else
    rc=$?
    firewall_clean >/dev/null 2>&1 || true
    restore_transparent_uci
    exit "$rc"
  fi
}

stop_service() {
  [ -x /etc/init.d/stargate ] || {
    echo "service script missing: /etc/init.d/stargate" >&2
    exit 1
  }
  /etc/init.d/stargate stop
  firewall_clean >/dev/null 2>&1 || true
  echo "service stopped"
}

status_json() {
  load_config
  service_state="unknown"
  if [ -x /etc/init.d/stargate ]; then
    service_state="$(/etc/init.d/stargate status 2>&1 || true)"
  fi
  singbox_version="$("$singbox_bin" version 2>/dev/null | head -1 || true)"
  printf '{'
  printf '"enabled":"%s",' "$(uci_get global enabled 0)"
  if [ -n "$node_server" ] && [ -n "$node_password" ]; then
    printf '"node_ready":true,'
  else
    printf '"node_ready":false,'
  fi
  printf '"node_server":"%s",' "$(printf '%s' "$node_server" | json_escape)"
  printf '"config_file":"%s",' "$config_file"
  printf '"backup_file":"%s",' "$backup_file"
  if [ -f "$backup_file" ]; then
    printf '"backup_ready":true,'
  else
    printf '"backup_ready":false,'
  fi
  printf '"transparent_proxy":%s,' "$(bool_json "$transparent_proxy")"
  printf '"transparent_mode":"%s",' "$transparent_mode"
  printf '"transparent_listen":"%s",' "$(printf '%s' "$transparent_listen" | json_escape)"
  printf '"transparent_port":"%s",' "$(printf '%s' "$transparent_port" | json_escape)"
  printf '"dns_hijack":%s,' "$(bool_json "$dns_hijack")"
  printf '"dns_hijack_port":"%s",' "$(printf '%s' "$dns_hijack_port" | json_escape)"
  printf '"firewall":%s,' "$(firewall_status_json)"
  printf '"socks_listen":"%s",' "$(printf '%s' "$socks_listen" | json_escape)"
  printf '"socks_port":"%s",' "$(printf '%s' "$socks_port" | json_escape)"
  printf '"http_listen":"%s",' "$(printf '%s' "$http_listen" | json_escape)"
  printf '"http_port":"%s",' "$(printf '%s' "$http_port" | json_escape)"
  printf '"service":%s,' "$(printf '%s' "$service_state" | json_escape | sed 's/^/"/;s/$/"/')"
  printf '"singbox":%s' "$(printf '%s' "$singbox_version" | json_escape | sed 's/^/"/;s/$/"/')"
  printf '}\n'
}

probe_url() {
  load_config
  target="${1:-}"
  case "$target" in
    baidu)
      name="Baidu"
      url="https://www.baidu.com/"
      ;;
    google)
      name="Google"
      url="https://www.google.com/generate_204"
      ;;
    github)
      name="GitHub"
      url="https://github.com/"
      ;;
    *)
      echo "unknown probe target: $target" >&2
      exit 2
      ;;
  esac

  if ! command -v curl >/dev/null 2>&1; then
    echo "$name curl missing"
    exit 1
  fi

  if ! /etc/init.d/stargate status >/dev/null 2>&1; then
    echo "$name Stargate is not running"
    exit 1
  fi

  firewall_active=0
  if firewall_status_text 2>/dev/null | grep -q '^Active: yes$'; then
    firewall_active=1
  fi

  mode="Stargate local proxy path"
  proxy_host="$http_listen"
  case "$proxy_host" in
    ''|0.0.0.0|::) proxy_host="127.0.0.1" ;;
  esac
  if [ "$transparent_proxy" = "1" ] && [ "$firewall_active" = "1" ]; then
    mode="Stargate transparent path"
  elif [ "$transparent_proxy" = "1" ]; then
    mode="Stargate local proxy path (forwarding inactive)"
  fi

  result="$(curl -L -sS -o /dev/null \
    --proxy "http://$proxy_host:$http_port" \
    --connect-timeout 5 \
    --max-time 10 \
    -w '%{http_code} %{time_total}' \
    "$url" 2>&1)" || {
      echo "$name $mode failed: $result"
      exit 1
    }

  code="${result%% *}"
  total="${result##* }"
  ms="$(awk "BEGIN { printf \"%d\", $total * 1000 }" 2>/dev/null || printf '?')"
  echo "$name $mode HTTP $code ${ms}ms"
}

logs_text() {
  logread -e stargate -e sing-box 2>/dev/null |
    sed 's/\x1b\[[0-9;]*m//g' |
    grep -v 'using outbound/direct\[direct\]: dial tcp .*: i/o timeout' |
    tail -160 || true
}

logs_raw() {
  logread -e stargate -e sing-box 2>/dev/null |
    sed 's/\x1b\[[0-9;]*m//g' |
    tail -220 || true
}

logs_clear() {
  if ubus call log clear >/dev/null 2>&1; then
    echo "logs cleared"
    return 0
  fi
  if [ -x /etc/init.d/log ]; then
    /etc/init.d/log restart >/dev/null 2>&1 || true
    echo "log service restarted"
    return 0
  fi
  echo "log clear is not supported on this firmware" >&2
  return 1
}

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

backup_create() {
  load_config
  output="${1:-}"
  [ -n "$output" ] || output="$tmp_prefix-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  tmp_dir="$(mktemp -d "$tmp_prefix-backup.XXXXXX")"
  trap 'rm -rf "$tmp_dir"' EXIT INT TERM

  mkdir -p "$tmp_dir/etc/config" "$tmp_dir/etc/stargate" "$tmp_dir/usr/share/stargate/rules"
  [ -f /etc/config/stargate ] && cp -a /etc/config/stargate "$tmp_dir/etc/config/stargate"
  if [ -d "$work_dir" ]; then
    find "$work_dir" -maxdepth 1 -type f \( -name '*.json' -o -name '*.env' -o -name 'env' \) -exec cp -a {} "$tmp_dir/etc/stargate/" \;
  fi
  for file in "$rules_direct_rule_set" "$rules_proxy_rule_set"; do
    if [ -f "$file" ]; then
      cp -a "$file" "$tmp_dir/usr/share/stargate/rules/$(basename "$file")"
    fi
  done
  {
    echo "name=stargate"
    echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "version=1"
  } >"$tmp_dir/manifest"
  tar -C "$tmp_dir" -czf "$output" manifest etc usr
  echo "$output"
}

backup_restore() {
  archive="${1:-}"
  [ -f "$archive" ] || {
    echo "backup archive missing: $archive" >&2
    exit 1
  }
  tmp_dir="$(mktemp -d "$tmp_prefix-restore.XXXXXX")"
  trap 'rm -rf "$tmp_dir"' EXIT INT TERM
  tar -C "$tmp_dir" -xzf "$archive"

  [ -f "$tmp_dir/etc/config/stargate" ] || {
    echo "invalid backup: missing etc/config/stargate" >&2
    exit 1
  }

  mkdir -p /etc/config /etc/stargate /usr/share/stargate/rules
  if [ -f /etc/config/stargate ]; then
    cp -a /etc/config/stargate "/etc/config/stargate.restore_from"
  fi
  cp -a "$tmp_dir/etc/config/stargate" /etc/config/stargate
  if [ -d "$tmp_dir/etc/stargate" ]; then
    find "$tmp_dir/etc/stargate" -maxdepth 1 -type f \( -name '*.json' -o -name '*.env' -o -name 'env' \) -exec cp -a {} /etc/stargate/ \;
  fi
  if [ -d "$tmp_dir/usr/share/stargate/rules" ]; then
    find "$tmp_dir/usr/share/stargate/rules" -maxdepth 1 -type f -name '*.json' -exec cp -a {} /usr/share/stargate/rules/ \;
  fi
  uci_commit || true
  echo "backup restored"
}

reset_defaults() {
  backup_create "$tmp_prefix-before-reset-$(date +%Y%m%d-%H%M%S).tar.gz" >/dev/null || true
  [ -x /etc/init.d/stargate ] && /etc/init.d/stargate stop >/dev/null 2>&1 || true
  cat > /etc/config/stargate <<'EOF'
config global 'global'
	option enabled '0'
	option log_level 'warn'
	option singbox_bin '/usr/bin/sing-box'
	option config_file '/etc/stargate/config.json'
	option work_dir '/etc/stargate'
	option auto_start '0'

config inbound 'inbound'
	option socks_listen '127.0.0.1'
	option socks_port '10808'
	option http_listen '127.0.0.1'
	option http_port '10809'
	option transparent_proxy '0'
	option transparent_mode 'redirect'
	option transparent_listen '0.0.0.0'
	option transparent_port '12345'

config node 'node'
	option type 'anytls'
	option label 'primary'
	option server ''
	option server_port '443'
	option password ''
	option sni ''
	option insecure '1'

config dns 'dns'
	option mode 'tcp_doh'
	option final 'direct-dns'
	option strategy 'prefer_ipv4'
	option local_preset 'alidns_tcp'
	option local_server '223.5.5.5'
	option local_type 'tcp'
	option local_path '/dns-query'
	option remote_preset 'quad9_doh'
	option remote_server '9.9.9.9'
	option remote_type 'https'
	option remote_path '/dns-query'
	option remote_detour 'anytls-out'
	option hijack_dns '1'
	option hijack_port '1053'

config rules 'rules'
	option mode 'blacklist'
	option source 'loyalsoldier'
	option source_base_url 'https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release'
	option direct_rule_set '/usr/share/stargate/rules/direct.json'
	option proxy_rule_set '/usr/share/stargate/rules/proxy.json'
	option block_quic '0'
	option private_direct '1'
	option custom_direct_domains ''
	option custom_proxy_domains ''
	option custom_direct_ips ''
	option custom_proxy_ips ''

config safety 'safety'
	option backup_on_apply '1'
EOF
  rm -f /etc/stargate/config.json.next
  uci_commit || true
  echo "default Stargate config restored; service stopped"
}

singbox_upgrade() {
  upload="${1:-}"
  [ -f "$upload" ] || {
    echo "uploaded sing-box binary missing: $upload" >&2
    exit 1
  }
  load_config
  install_dir="$(dirname "$singbox_bin")"
  backup_dir="/usr/share/stargate/backup"
  backup_bin="$backup_dir/sing-box.bak"
  tmp_bin="$tmp_prefix-sing-box.new"

  mkdir -p "$install_dir" "$backup_dir"
  cp -f "$upload" "$tmp_bin"
  chmod 0755 "$tmp_bin"
  "$tmp_bin" version >/dev/null 2>&1 || {
    rm -f "$tmp_bin"
    echo "uploaded file is not a runnable sing-box binary" >&2
    exit 1
  }

  if [ -x "$singbox_bin" ]; then
    cp -a "$singbox_bin" "$backup_bin"
  fi
  cp -f "$tmp_bin" "$singbox_bin"
  chmod 0755 "$singbox_bin"
  rm -f "$tmp_bin"
  "$singbox_bin" version | head -1
  echo "sing-box upgraded: $singbox_bin"
}

singbox_rollback() {
  load_config
  backup_bin="/usr/share/stargate/backup/sing-box.bak"
  [ -x "$backup_bin" ] || {
    echo "sing-box backup not found: $backup_bin" >&2
    exit 1
  }
  cp -a "$backup_bin" "$singbox_bin"
  chmod 0755 "$singbox_bin"
  "$singbox_bin" version | head -1
  echo "sing-box rolled back: $singbox_bin"
}

action="${1:-}"
case "$action" in
  generate) generate_config ;;
  check) generated="$(generate_config)"; next_file="$generated"; check_next ;;
  apply) apply_config ;;
  rollback) rollback_config ;;
  start) start_local_proxy ;;
  start-transparent) start_transparent_proxy "${2:-redirect}" "${3:-}" ;;
  stop) stop_service ;;
  status) status_json ;;
  firewall-apply) firewall_apply ;;
  firewall-clean) firewall_clean ;;
  firewall-status) firewall_status_text ;;
  probe) probe_url "${2:-}" ;;
  node-add) node_add_values "${2:-}" "${3:-}" "${4:-443}" "${5:-}" "${6:-}" "${7:-1}" ;;
  node-add-link) node_add_link "${2:-}" ;;
  node-update) node_update "${2:-}" "${3:-}" "${4:-}" "${5:-443}" "${6:-}" "${7:-}" "${8:-1}" ;;
  node-list) node_list ;;
  node-use) node_use "${2:-}" ;;
  node-delete) node_delete "${2:-}" ;;
  rules-update) rules_update ;;
  rules-update-start) rules_update_start ;;
  rules-status) rules_status ;;
  rules-test) rules_test "${2:-}" ;;
  backup-create) backup_create "${2:-}" ;;
  backup-restore) backup_restore "${2:-}" ;;
  reset-defaults) reset_defaults ;;
  singbox-upgrade) singbox_upgrade "${2:-}" ;;
  singbox-rollback) singbox_rollback ;;
  logs) logs_text ;;
  logs-raw) logs_raw ;;
  logs-clear) logs_clear ;;
  -h|--help|help|"") usage ;;
  *) usage >&2; exit 2 ;;
esac
