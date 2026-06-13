# shellcheck shell=sh
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
  uci_cmd set "$app.global.enabled=1"
  ensure_inbound_section
  uci_cmd set "$app.inbound.transparent_proxy=0"
  uci_commit
  if apply_config && restart_service_with_rollback; then
    set_init_enabled 1
    firewall_clean >/dev/null 2>&1 || true
    echo "started local proxy mode"
  else
    rc=$?
    set_init_enabled 0
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
  uci_cmd set "$app.global.enabled=1"
  ensure_inbound_section
  uci_cmd set "$app.inbound.transparent_proxy=1"
  uci_cmd set "$app.inbound.transparent_mode=$mode"
  uci_cmd set "$app.inbound.transparent_listen=$(uci_get inbound transparent_listen 0.0.0.0)"
  uci_cmd set "$app.inbound.transparent_port=$port"
  uci_commit
  if apply_config && restart_service_with_rollback && firewall_apply_rules; then
    set_init_enabled 1
    echo "started transparent proxy mode: $mode"
  else
    rc=$?
    set_init_enabled 0
    firewall_clean >/dev/null 2>&1 || true
    restore_transparent_uci
    exit "$rc"
  fi
}

set_init_enabled() {
  [ -x /etc/init.d/stargate ] || return 0
  if [ "${1:-0}" = "1" ]; then
    /etc/init.d/stargate enable >/dev/null 2>&1 || true
  else
    /etc/init.d/stargate disable >/dev/null 2>&1 || true
  fi
}

apply_runtime_state() {
  load_config
  app_enabled="$(bool_value "$(uci_get global enabled 0)")"

  if [ "$app_enabled" != "1" ]; then
    uci_cmd set "$app.global.enabled=0"
    ensure_inbound_section
    uci_cmd set "$app.inbound.transparent_proxy=0"
    uci_commit
    set_init_enabled 0
    stop_service
    echo "runtime disabled"
    return 0
  fi

  if [ "$transparent_proxy" = "1" ]; then
    start_transparent_proxy "$transparent_mode" "$transparent_port"
  else
    start_local_proxy
  fi
}

stop_service() {
  [ -x /etc/init.d/stargate ] || {
    echo "service script missing: /etc/init.d/stargate" >&2
    exit 1
  }
  uci_cmd set "$app.global.enabled=0" 2>/dev/null || true
  ensure_inbound_section
  uci_cmd set "$app.inbound.transparent_proxy=0" 2>/dev/null || true
  uci_commit 2>/dev/null || true
  set_init_enabled 0
  if /etc/init.d/stargate status >/dev/null 2>&1; then
    /etc/init.d/stargate stop
  else
    /etc/init.d/stargate stop >/dev/null 2>&1 || true
  fi
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
