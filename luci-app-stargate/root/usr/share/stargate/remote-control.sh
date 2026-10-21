#!/bin/sh
set -eu
umask 077
action=${1:-}
[ $# -gt 0 ] && shift
[ "$(id -u)" = 0 ] || exit 1
dir=/etc/stargate-remote
agent=/usr/bin/stargate-remote
service=/etc/init.d/stargate-remote
lock=/var/lock/stargate-remote-install
temporary=
config_locked=0
mkdir -p /var/lock
mkdir "$lock" 2>/dev/null || { echo 'Maintenance is in progress.' >&2; exit 1; }
cleanup() {
  [ "$config_locked" = 0 ] || rmdir "$dir/.update-lock" 2>/dev/null || true
  [ -z "$temporary" ] || rm -rf "$temporary"
  rmdir "$lock" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
export STARGATE_REMOTE_LOCK_HELD=1
wait_configuration() {
  [ -d "$dir" ] || return 0
  attempt=0
  while [ "$attempt" -lt 60 ]; do
    if mkdir "$dir/.update-lock" 2>/dev/null; then
      config_locked=1
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  echo 'A configuration update is still active.' >&2
  return 1
}
release_configuration() {
  [ "$config_locked" = 0 ] || rmdir "$dir/.update-lock"
  config_locked=0
}
[ -x "$agent" ] && [ -x /usr/bin/frpc ] && [ -x /usr/bin/sing-box ] && [ -x "$service" ] || {
  echo 'Install the remote-access component first.' >&2; exit 1;
}
case "$action" in
  enroll)
    link=
    activate=0
    import_proxy=0
    while [ $# -gt 0 ]; do
      [ $# -ge 2 ] || exit 1
      case "$1" in
        --link-file) link=$2 ;;
        --activate) activate=$2 ;;
        --import-proxy) import_proxy=$2 ;;
        *) exit 1 ;;
      esac
      shift 2
    done
    case "$activate:$import_proxy" in 0:0|0:1|1:0|1:1) ;; *) exit 1 ;; esac
    [ -f "$link" ] && [ ! -L "$link" ] || exit 1
    [ ! -e "$dir/profile.json" ] || { echo 'This device is already enrolled.' >&2; exit 1; }
    "$agent" enroll --dir "$dir" --link-file "$link"
    "$agent" prepare --dir "$dir"
    if [ "$import_proxy" = 1 ]; then
      temporary=$(mktemp -d /tmp/stargate-remote-import.XXXXXX)
      "$agent" proxy-export --dir "$dir" --output "$temporary/proxy.link"
      if ! /usr/share/stargate/stargate.sh node-add-link-file "$temporary/proxy.link" >/dev/null; then
        echo 'Remote enrollment saved; ordinary proxy import failed.' >&2
        exit 1
      fi
    fi
    if [ "$activate" = 0 ]; then
      wait_configuration
      "$service" stop
      release_configuration
      "$service" disable
    else
      "$service" enable
      "$service" start
      "$agent" sync --dir "$dir"
    fi
    ;;
  start)
    [ $# = 0 ] && [ -f "$dir/profile.json" ] || exit 1
    wait_configuration
    release_configuration
    "$agent" prepare --dir "$dir"
    "$service" enable
    "$service" start
    "$agent" sync --dir "$dir"
    ;;
  stop)
    [ $# = 0 ] || exit 1
    wait_configuration
    "$service" stop
    release_configuration
    "$service" disable
    ;;
  *) echo 'usage: remote-control.sh enroll|start|stop [options]' >&2; exit 1 ;;
esac
