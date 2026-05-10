#!/bin/sh
set -eu

app="stargate"
work_dir="/etc/stargate"
config_file="$work_dir/config.json"
next_file="$config_file.next"
backup_file="$config_file.bak"
singbox_bin="/usr/bin/sing-box"

usage() {
  cat <<'USAGE'
Usage:
  /usr/share/stargate/stargate.sh generate
  /usr/share/stargate/stargate.sh check
  /usr/share/stargate/stargate.sh apply
  /usr/share/stargate/stargate.sh status
  /usr/share/stargate/stargate.sh probe baidu|google|github
  /usr/share/stargate/stargate.sh node-add label server port password sni insecure
  /usr/share/stargate/stargate.sh node-add-link anytls://...
  /usr/share/stargate/stargate.sh node-update id label server port password sni insecure
  /usr/share/stargate/stargate.sh node-list
  /usr/share/stargate/stargate.sh node-use id
  /usr/share/stargate/stargate.sh node-delete id
  /usr/share/stargate/stargate.sh rules-update
  /usr/share/stargate/stargate.sh rules-status
  /usr/share/stargate/stargate.sh logs
USAGE
}

json_escape() {
  sed 's/\\/\\\\/g; s/"/\\"/g'
}

bool_json() {
  case "${1:-0}" in
    1|true|TRUE|yes|on) printf true ;;
    *) printf false ;;
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
  dns_remote_preset="$(uci_get dns remote_preset cloudflare_doh)"
  dns_remote_server="$(uci_get dns remote_server 1.1.1.1)"
  dns_remote_type="$(uci_get dns remote_type https)"
  dns_remote_path="$(uci_get dns remote_path /dns-query)"
  dns_remote_detour="$(uci_get dns remote_detour anytls-out)"

  rules_mode="$(uci_get rules mode ruleset)"
  rules_default_outbound="$(uci_get rules default_outbound direct)"
  rules_proxy_outbound="$(uci_get rules proxy_outbound anytls-out)"
  rules_source="$(uci_get rules source loyalsoldier)"
  rules_source_base_url="$(uci_get rules source_base_url https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release)"
  rules_direct_rule_set="$(uci_get rules direct_rule_set /usr/share/stargate/rules/direct.json)"
  rules_proxy_rule_set="$(uci_get rules proxy_rule_set /usr/share/stargate/rules/proxy.json)"
  rules_custom_direct_domains="$(uci_get rules custom_direct_domains '')"
  rules_custom_proxy_domains="$(uci_get rules custom_proxy_domains '')"
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
  case "$rules_mode" in ruleset|global_proxy|direct) ;; *) echo "unsupported rules mode: $rules_mode" >&2; exit 1 ;; esac
  case "$rules_default_outbound" in direct|anytls-out) ;; *) echo "unsupported default outbound: $rules_default_outbound" >&2; exit 1 ;; esac
  case "$rules_proxy_outbound" in direct|anytls-out) ;; *) echo "unsupported proxy outbound: $rules_proxy_outbound" >&2; exit 1 ;; esac
  if [ "$rules_mode" = "ruleset" ]; then
    [ -f "$rules_direct_rule_set" ] || {
      echo "direct rule-set missing: run Rules -> Update Loyalsoldier rules first ($rules_direct_rule_set)" >&2
      exit 1
    }
    [ -f "$rules_proxy_rule_set" ] || {
      echo "proxy rule-set missing: run Rules -> Update Loyalsoldier rules first ($rules_proxy_rule_set)" >&2
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
  direct_count=0
  proxy_count=0
  [ -f "$rules_direct_rule_set" ] && direct_count="$(grep -o '"' "$rules_direct_rule_set" 2>/dev/null | wc -l | awk '{print int($1 / 2)}')"
  [ -f "$rules_proxy_rule_set" ] && proxy_count="$(grep -o '"' "$rules_proxy_rule_set" 2>/dev/null | wc -l | awk '{print int($1 / 2)}')"
  printf 'source=%s\n' "$rules_source"
  printf 'direct=%s %s\n' "$rules_direct_rule_set" "$direct_count"
  printf 'proxy=%s %s\n' "$rules_proxy_rule_set" "$proxy_count"
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
  curl -fsSL --connect-timeout 8 --max-time 60 "$base/direct-list.txt" -o "$tmp_dir/direct-list.txt"
  curl -fsSL --connect-timeout 8 --max-time 60 "$base/proxy-list.txt" -o "$tmp_dir/proxy-list.txt"
  [ -s "$tmp_dir/direct-list.txt" ] || { echo "downloaded direct list is empty" >&2; exit 1; }
  [ -s "$tmp_dir/proxy-list.txt" ] || { echo "downloaded proxy list is empty" >&2; exit 1; }
  write_rule_set_json "$tmp_dir/direct-list.txt" "$rules_direct_rule_set"
  write_rule_set_json "$tmp_dir/proxy-list.txt" "$rules_proxy_rule_set"
  echo "rules updated:"
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
  if [ "$rules_mode" = "ruleset" ]; then
    printf '      { "rule_set": "direct", "server": "direct-dns" },\n'
    printf '      { "rule_set": "proxy", "server": "remote-doh" }\n'
  fi
}

write_rule_sets() {
  if [ "$rules_mode" = "ruleset" ]; then
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

  if [ "$rules_block_quic" = "1" ]; then
    add_rule '{ "network": "udp", "port": 443, "action": "reject" }'
  fi
  if [ "$rules_private_direct" = "1" ]; then
    add_rule '{ "ip_is_private": true, "outbound": "direct" }'
  fi
  if [ "$rules_mode" = "ruleset" ]; then
    custom_direct_rule="$(write_inline_domain_rule "$rules_custom_direct_domains" "direct")"
    custom_proxy_rule="$(write_inline_domain_rule "$rules_custom_proxy_domains" "$rules_proxy_outbound")"
    [ -z "$custom_direct_rule" ] || add_rule "$custom_direct_rule"
    [ -z "$custom_proxy_rule" ] || add_rule "$custom_proxy_rule"
    add_rule '{ "rule_set": "direct", "outbound": "direct" }'
    add_rule '{ "rule_set": "proxy", "outbound": "'"$rules_proxy_outbound"'" }'
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
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "$socks_listen",
      "listen_port": $socks_port
    },
    {
      "type": "http",
      "tag": "http-in",
      "listen": "$http_listen",
      "listen_port": $http_port
    }
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

  result="$(curl -L -sS -o /dev/null \
    --connect-timeout 5 \
    --max-time 10 \
    -w '%{http_code} %{time_total}' \
    "$url" 2>&1)" || {
      echo "$name failed: $result"
      exit 1
    }

  code="${result%% *}"
  total="${result##* }"
  ms="$(awk "BEGIN { printf \"%d\", $total * 1000 }" 2>/dev/null || printf '?')"
  echo "$name HTTP $code ${ms}ms"
}

logs_text() {
  logread -e stargate -e sing-box 2>/dev/null | tail -80 || true
}

action="${1:-}"
case "$action" in
  generate) generate_config ;;
  check) generated="$(generate_config)"; next_file="$generated"; check_next ;;
  apply) apply_config ;;
  status) status_json ;;
  probe) probe_url "${2:-}" ;;
  node-add) node_add_values "${2:-}" "${3:-}" "${4:-443}" "${5:-}" "${6:-}" "${7:-1}" ;;
  node-add-link) node_add_link "${2:-}" ;;
  node-update) node_update "${2:-}" "${3:-}" "${4:-}" "${5:-443}" "${6:-}" "${7:-}" "${8:-1}" ;;
  node-list) node_list ;;
  node-use) node_use "${2:-}" ;;
  node-delete) node_delete "${2:-}" ;;
  rules-update) rules_update ;;
  rules-status) rules_status ;;
  logs) logs_text ;;
  -h|--help|help|"") usage ;;
  *) usage >&2; exit 2 ;;
esac
