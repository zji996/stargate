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

