#!/bin/sh
set -eu

service_name="stargate"
config_dir="/etc/stargate"
config_file="$config_dir/config.json"
env_file="$config_dir/env"
init_file="/etc/init.d/$service_name"
singbox_bin="${SINGBOX_BIN:-/usr/bin/sing-box}"
default_socks="127.0.0.1:10808"
default_http="127.0.0.1:10809"

usage() {
  cat <<'USAGE'
Usage:
  stargate.sh install
  stargate.sh configure
  stargate.sh status
  stargate.sh start
  stargate.sh stop
  stargate.sh restart
  stargate.sh check
  stargate.sh uninstall

Environment:
  SINGBOX_BIN=/usr/bin/sing-box
USAGE
}

require_root() {
  if [ "$(id -u)" != "0" ]; then
    echo "please run as root" >&2
    exit 1
  fi
}

require_singbox() {
  if [ ! -x "$singbox_bin" ]; then
    echo "sing-box not found: $singbox_bin" >&2
    echo "install sing-box first, or set SINGBOX_BIN=/path/to/sing-box" >&2
    exit 1
  fi
}

split_host_port() {
  hp="$1"
  default_port="$2"
  case "$hp" in
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

parse_anytls_uri() {
  uri="$1"
  case "$uri" in
    anytls://*) ;;
    *)
      echo "only anytls:// URI is supported now" >&2
      exit 1
      ;;
  esac

  rest="${uri#anytls://}"
  query=""
  case "$rest" in
    *\?*)
      query="${rest#*\?}"
      rest="${rest%%\?*}"
      ;;
  esac

  userinfo=""
  hostport="$rest"
  case "$rest" in
    *@*)
      userinfo="${rest%@*}"
      hostport="${rest#*@}"
      ;;
  esac

  password="$(uri_decode "$userinfo")"
  split_host_port "$hostport" "443"
  sni="$(uri_decode "$(query_value "$query" sni)")"
  insecure="$(query_value "$query" insecure)"
  case "$insecure" in
    1|true|TRUE|True) insecure="true" ;;
    0|false|FALSE|False) insecure="false" ;;
    "") insecure="true" ;;
    *) insecure="true" ;;
  esac
}

json_escape() {
  sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_config() {
  out="$1"
  socks_addr="$2"
  http_addr="$3"
  server="$4"
  server_port="$5"
  password="$6"
  insecure="$7"
  sni="$8"

  socks_host="${socks_addr%:*}"
  socks_port="${socks_addr##*:}"
  http_host="${http_addr%:*}"
  http_port="${http_addr##*:}"
  esc_server="$(printf '%s' "$server" | json_escape)"
  esc_password="$(printf '%s' "$password" | json_escape)"
  esc_sni="$(printf '%s' "$sni" | json_escape)"

  tls_server_name=""
  if [ -n "$sni" ]; then
    tls_server_name=", \"server_name\": \"$esc_sni\""
  fi

  cat >"$out" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "dns": {
    "servers": [
      { "tag": "local", "type": "local" },
      { "tag": "direct", "type": "udp", "server": "223.5.5.5" },
      { "tag": "remote", "type": "tls", "server": "1.1.1.1", "detour": "anytls-out" }
    ],
    "final": "remote",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "$socks_host",
      "listen_port": $socks_port
    },
    {
      "type": "http",
      "tag": "http-in",
      "listen": "$http_host",
      "listen_port": $http_port
    }
  ],
  "outbounds": [
    {
      "type": "anytls",
      "tag": "anytls-out",
      "server": "$esc_server",
      "server_port": $server_port,
      "password": "$esc_password",
      "idle_session_check_interval": "30s",
      "idle_session_timeout": "30s",
      "min_idle_session": 5,
      "tls": {
        "enabled": true,
        "insecure": $insecure$tls_server_name
      }
    },
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "rules": [
      { "ip_is_private": true, "outbound": "direct" }
    ],
    "final": "anytls-out"
  }
}
EOF
}

check_config_file() {
  require_singbox
  "$singbox_bin" check -c "$1"
}

install_init() {
  cat >"$init_file" <<'EOF'
#!/bin/sh /etc/rc.common

START=95
STOP=20
USE_PROCD=1

name="stargate"
command="/usr/bin/sing-box"
config="/etc/stargate/config.json"

start_service() {
  [ -x "$command" ] || {
    echo "sing-box missing: $command" >&2
    return 1
  }
  [ -f "$config" ] || {
    echo "config missing: $config" >&2
    return 1
  }
  "$command" check -c "$config" || return 1
  procd_open_instance
  procd_set_param command "$command" run -c "$config"
  procd_set_param respawn 3600 5 5
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
EOF
  chmod +x "$init_file"
}

install_service() {
  require_root
  require_singbox
  mkdir -p "$config_dir"
  install_init
  [ -f "$env_file" ] || {
    {
      echo "SOCKS=$default_socks"
      echo "HTTP=$default_http"
    } >"$env_file"
  }
  echo "installed $init_file"
  echo "run: sh scripts/stargate.sh configure"
}

configure() {
  require_root
  require_singbox
  mkdir -p "$config_dir"
  socks="$default_socks"
  http="$default_http"
  [ -f "$env_file" ] && . "$env_file"
  socks="${SOCKS:-$socks}"
  http="${HTTP:-$http}"

  printf "AnyTLS URI: "
  read -r uri
  printf "SOCKS listen [%s]: " "$socks"
  read -r input_socks
  [ -n "$input_socks" ] && socks="$input_socks"
  printf "HTTP listen [%s]: " "$http"
  read -r input_http
  [ -n "$input_http" ] && http="$input_http"

  parse_anytls_uri "$uri"
  next="$config_file.next"
  write_config "$next" "$socks" "$http" "$host" "$port" "$password" "$insecure" "$sni"
  check_config_file "$next"
  [ -f "$config_file" ] && cp -a "$config_file" "$config_file.bak"
  mv "$next" "$config_file"
  {
    echo "SOCKS=$socks"
    echo "HTTP=$http"
  } >"$env_file"
  echo "config written: $config_file"
}

start_service_cmd() {
  require_root
  "$init_file" enable
  "$init_file" start || {
    echo "start failed" >&2
    if [ -f "$config_file.bak" ]; then
      echo "rolling back config" >&2
      cp -a "$config_file.bak" "$config_file"
      "$init_file" restart || true
    fi
    exit 1
  }
}

status_cmd() {
  echo "Service:"
  "$init_file" status 2>&1 || true
  echo
  echo "Config:"
  [ -f "$config_file" ] && ls -lh "$config_file" || echo "missing $config_file"
  echo
  echo "Listeners:"
  netstat -lntp 2>/dev/null | grep -E '10808|10809|sing-box' || true
  echo
  echo "sing-box:"
  "$singbox_bin" version 2>&1 | head -8 || true
}

action="${1:-}"
case "$action" in
  install) install_service ;;
  configure) configure ;;
  check) check_config_file "$config_file" ;;
  start) start_service_cmd ;;
  stop) require_root; "$init_file" stop ;;
  restart) require_root; "$init_file" restart ;;
  status) status_cmd ;;
  uninstall)
    require_root
    "$init_file" stop 2>/dev/null || true
    "$init_file" disable 2>/dev/null || true
    rm -f "$init_file"
    echo "removed service; config kept at $config_dir"
    ;;
  -h|--help|help|"") usage ;;
  *) usage >&2; exit 2 ;;
esac
