# shellcheck shell=sh
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
  validate_port_value "${node_port:-443}" "node port" || exit 1
  if [ "${node_enable_port:-0}" = "1" ]; then
    if [ -n "${node_socks_port:-}" ]; then
      validate_port_value "$node_socks_port" "node SOCKS port" || exit 1
    fi
    if [ -n "${node_http_port:-}" ]; then
      validate_port_value "$node_http_port" "node HTTP port" || exit 1
    fi
    if [ -z "${node_socks_port:-}" ] && [ -z "${node_http_port:-}" ]; then
      echo "at least one port (SOCKS or HTTP) is required when dedicated port is enabled" >&2
      exit 1
    fi
    if [ -n "${node_socks_port:-}" ] && [ -n "${node_http_port:-}" ] && [ "$node_socks_port" = "$node_http_port" ]; then
      echo "node SOCKS port and HTTP port cannot be the same" >&2
      exit 1
    fi
    validate_listen_address "${node_listen:-0.0.0.0}" "node listen address" || exit 1
    check_dedicated_port_conflicts "${node_self_id:-}" "${node_socks_port:-}" "${node_http_port:-}"
  fi
}

# Fail early when a dedicated port collides with the main inbounds, the
# transparent/DNS ports or another node's dedicated ports. Report the same
# thing here that validate_config would report at apply time.
# check_dedicated_port_conflicts <self id or empty> <socks port> <http port> [replaced id]
check_dedicated_port_conflicts() {
  self_id="$1"
  candidate_socks="$2"
  candidate_http="$3"
  replaced_id="${4:-}"
  nl='
'
  # One "port|label" entry per line; labels may contain spaces.
  reserved="$(uci_get inbound socks_port 10808)|main SOCKS port"
  reserved="$reserved$nl$(uci_get inbound http_port 10809)|main HTTP port"
  if [ "$(bool_value "$(uci_get inbound transparent_proxy 0)")" = "1" ]; then
    reserved="$reserved$nl$(uci_get inbound transparent_port 12345)|transparent proxy port"
    if [ "$(bool_value "$(uci_get dns hijack_dns 1)")" = "1" ]; then
      reserved="$reserved$nl$(uci_get dns hijack_port 1053)|DNS hijack port"
    fi
  fi
  for other_id in $(list_node_item_ids); do
    [ "$other_id" != "$self_id" ] || continue
    [ "$other_id" != "$replaced_id" ] || continue
    [ "$(bool_value "$(uci_get "$other_id" enable_port 0)")" = "1" ] || continue
    other_socks="$(uci_get "$other_id" socks_port '')"
    other_http="$(uci_get "$other_id" http_port '')"
    [ -z "$other_socks" ] || reserved="$reserved$nl$other_socks|node $other_id SOCKS port"
    [ -z "$other_http" ] || reserved="$reserved$nl$other_http|node $other_id HTTP port"
  done
  old_ifs="$IFS"
  IFS="$nl"
  for entry in $reserved; do
    IFS="$old_ifs"
    used_port="${entry%%|*}"
    used_label="${entry#*|}"
    [ -n "$used_port" ] || continue
    if [ -n "$candidate_socks" ] && [ "$candidate_socks" = "$used_port" ]; then
      echo "dedicated SOCKS port $candidate_socks conflicts with $used_label" >&2
      exit 1
    fi
    if [ -n "$candidate_http" ] && [ "$candidate_http" = "$used_port" ]; then
      echo "dedicated HTTP port $candidate_http conflicts with $used_label" >&2
      exit 1
    fi
    IFS="$nl"
  done
  IFS="$old_ifs"
}

node_add_values() {
  node_label="${1:-}"
  node_server="${2:-}"
  node_port="${3:-443}"
  node_password="${4:-}"
  node_sni="${5:-}"
  node_insecure="${6:-1}"
  node_enable_port="${7:-0}"
  node_socks_port="${8:-}"
  node_http_port="${9:-}"
  node_listen="${10:-0.0.0.0}"
  node_type="anytls"
  [ -n "$node_label" ] || node_label="$node_server"
  [ -n "$node_port" ] || node_port="443"
  case "$node_insecure" in 1|true|TRUE|yes|on) node_insecure="1" ;; *) node_insecure="0" ;; esac
  case "$node_enable_port" in 1|true|TRUE|yes|on) node_enable_port="1" ;; *) node_enable_port="0" ;; esac
  node_self_id=""
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
  uci_cmd set "$app.$id.enable_port=$node_enable_port"
  uci_cmd set "$app.$id.socks_port=$node_socks_port"
  uci_cmd set "$app.$id.http_port=$node_http_port"
  uci_cmd set "$app.$id.listen=$node_listen"
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
  if [ "$#" -ge 8 ]; then
    node_enable_port="${8:-0}"
    node_socks_port="${9:-}"
    node_http_port="${10:-}"
    node_listen="${11:-0.0.0.0}"
  else
    node_enable_port="$(uci_get "$id" enable_port 0)"
    node_socks_port="$(uci_get "$id" socks_port '')"
    node_http_port="$(uci_get "$id" http_port '')"
    node_listen="$(uci_get "$id" listen '0.0.0.0')"
  fi
  node_type="anytls"
  [ -n "$node_label" ] || node_label="$node_server"
  [ -n "$node_port" ] || node_port="443"
  [ -n "$node_password" ] || node_password="$(uci_get "$id" password '')"
  case "$node_insecure" in 1|true|TRUE|yes|on) node_insecure="1" ;; *) node_insecure="0" ;; esac
  case "$node_enable_port" in 1|true|TRUE|yes|on) node_enable_port="1" ;; *) node_enable_port="0" ;; esac
  node_self_id="$id"
  validate_node_fields

  uci_cmd set "$app.$id.type=anytls"
  uci_cmd set "$app.$id.label=$node_label"
  uci_cmd set "$app.$id.server=$node_server"
  uci_cmd set "$app.$id.server_port=$node_port"
  uci_cmd set "$app.$id.password=$node_password"
  uci_cmd set "$app.$id.sni=$node_sni"
  uci_cmd set "$app.$id.insecure=$node_insecure"
  uci_cmd set "$app.$id.enable_port=$node_enable_port"
  uci_cmd set "$app.$id.socks_port=$node_socks_port"
  uci_cmd set "$app.$id.http_port=$node_http_port"
  uci_cmd set "$app.$id.listen=$node_listen"
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
    enable_port="$(uci_get "$id" enable_port 0)"
    socks_port="$(uci_get "$id" socks_port '')"
    http_port="$(uci_get "$id" http_port '')"
    listen="$(uci_get "$id" listen '0.0.0.0')"
    port_label="$(uci_get "$id" port_label '')"
    active=0
    if [ "$server" = "$active_server" ] && [ "$port" = "$active_port" ]; then
      active=1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$active" "$type" "$label" "$server" "$port" "$sni" "$insecure" "$enable_port" "$socks_port" "$http_port" "$listen" "$port_label"
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

node_port_set() {
  id="${1:-}"
  case "$id" in ''|*[!A-Za-z0-9_-]*) echo "invalid node id" >&2; exit 1 ;; esac
  [ "$(uci_get "$id" type '')" = "anytls" ] || {
    echo "node not found or unsupported: $id" >&2
    exit 1
  }
  socks_port="${2:-}"
  http_port="${3:-}"
  listen="${4:-0.0.0.0}"
  port_label="${5:-}"
  old_node_id="${6:-}"

  replaced_id=""
  if [ -n "$old_node_id" ] && [ "$old_node_id" != "$id" ]; then
    case "$old_node_id" in
      *[!A-Za-z0-9_-]*) echo "invalid original node id" >&2; exit 1 ;;
    esac
    [ "$(uci_get "$old_node_id" type '')" = "anytls" ] || {
      echo "original node not found or unsupported: $old_node_id" >&2
      exit 1
    }
    [ "$(bool_value "$(uci_get "$old_node_id" enable_port 0)")" = "1" ] || {
      echo "original node has no dedicated port: $old_node_id" >&2
      exit 1
    }
    replaced_id="$old_node_id"
  fi

  if [ -n "$socks_port" ]; then
    validate_port_value "$socks_port" "node SOCKS port" || exit 1
  fi
  if [ -n "$http_port" ]; then
    validate_port_value "$http_port" "node HTTP port" || exit 1
  fi
  if [ -z "$socks_port" ] && [ -z "$http_port" ]; then
    echo "at least one port (SOCKS or HTTP) is required" >&2
    exit 1
  fi
  if [ -n "$socks_port" ] && [ -n "$http_port" ] && [ "$socks_port" = "$http_port" ]; then
    echo "node SOCKS port and HTTP port cannot be the same" >&2
    exit 1
  fi
  validate_listen_address "$listen" "node listen address" || exit 1
  check_dedicated_port_conflicts "$id" "$socks_port" "$http_port" "$replaced_id"

  if [ -n "$replaced_id" ]; then
    uci_cmd set "$app.$replaced_id.enable_port=0"
    uci_cmd set "$app.$replaced_id.socks_port="
    uci_cmd set "$app.$replaced_id.http_port="
    uci_cmd set "$app.$replaced_id.port_label="
  fi

  uci_cmd set "$app.$id.enable_port=1"
  uci_cmd set "$app.$id.socks_port=$socks_port"
  uci_cmd set "$app.$id.http_port=$http_port"
  uci_cmd set "$app.$id.listen=$listen"
  uci_cmd set "$app.$id.port_label=$port_label"
  uci_commit
  echo "dedicated port updated for node: $id"
}

node_port_remove() {
  id="${1:-}"
  case "$id" in ''|*[!A-Za-z0-9_-]*) echo "invalid node id" >&2; exit 1 ;; esac
  [ "$(uci_get "$id" type '')" = "anytls" ] || {
    echo "node not found or unsupported: $id" >&2
    exit 1
  }
  uci_cmd set "$app.$id.enable_port=0"
  uci_cmd set "$app.$id.socks_port="
  uci_cmd set "$app.$id.http_port="
  uci_cmd set "$app.$id.port_label="
  uci_commit
  echo "dedicated port removed for node: $id"
}

node_next_ports() {
  base_socks=10818
  base_http=10819
  candidate_socks=$base_socks
  candidate_http=$base_http

  while :; do
    conflict=0
    main_socks="$(uci_get inbound socks_port 10808)"
    main_http="$(uci_get inbound http_port 10809)"
    trans_port="$(uci_get inbound transparent_port 12345)"
    dns_port="$(uci_get dns hijack_port 1053)"
    for p in "$main_socks" "$main_http" "$trans_port" "$dns_port"; do
      if [ "$candidate_socks" = "$p" ] || [ "$candidate_http" = "$p" ]; then
        conflict=1
        break
      fi
    done
    if [ "$conflict" = "0" ]; then
      for other_id in $(list_node_item_ids); do
        if [ "$(bool_value "$(uci_get "$other_id" enable_port 0)")" = "1" ]; then
          o_socks="$(uci_get "$other_id" socks_port '')"
          o_http="$(uci_get "$other_id" http_port '')"
          if [ -n "$o_socks" ] && { [ "$candidate_socks" = "$o_socks" ] || [ "$candidate_http" = "$o_socks" ]; }; then
            conflict=1
            break
          fi
          if [ -n "$o_http" ] && { [ "$candidate_socks" = "$o_http" ] || [ "$candidate_http" = "$o_http" ]; }; then
            conflict=1
            break
          fi
        fi
      done
    fi
    if [ "$conflict" = "0" ] && [ -r /proc/net/tcp ]; then
      hex_socks="$(printf '%04X' "$candidate_socks")"
      hex_http="$(printf '%04X' "$candidate_http")"
      if grep -qi ":$hex_socks .* 0A " /proc/net/tcp 2>/dev/null || \
         grep -qi ":$hex_socks .* 0A " /proc/net/tcp6 2>/dev/null || \
         grep -qi ":$hex_http .* 0A " /proc/net/tcp 2>/dev/null || \
         grep -qi ":$hex_http .* 0A " /proc/net/tcp6 2>/dev/null; then
        conflict=1
      fi
    fi
    if [ "$conflict" = "0" ]; then
      printf '%s\t%s\n' "$candidate_socks" "$candidate_http"
      return 0
    fi
    candidate_socks=$((candidate_socks + 2))
    candidate_http=$((candidate_http + 2))
    if [ "$candidate_socks" -ge 65534 ]; then
      printf '10818\t10819\n'
      return 0
    fi
  done
}
