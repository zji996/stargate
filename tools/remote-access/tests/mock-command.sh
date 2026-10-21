#!/bin/sh
set -eu
name=${0##*/}
mkdir -p /test-state
case "$name" in
  sleep) exit 0 ;;
  chown|useradd|userdel|groupadd) exit 0 ;;
  getent) [ "${1:-}" != passwd ] || exit 0; exit 1 ;;
  cp|install)
    if [ -e /fail/cp ]; then rm -f /fail/cp; exit 1; fi
    if [ -e /fail/copy-target ]; then
      target=$(cat /fail/copy-target)
      for argument in "$@"; do
        if [ "$argument" = "$target" ]; then rm -f /fail/copy-target; exit 1; fi
      done
    fi
    exec "/host/usr/bin/$name" "$@"
    ;;
  systemctl)
    action=$1; shift
    case "$action" in
      daemon-reload) exit 0 ;;
      is-active|is-enabled)
        [ "${1:-}" != --quiet ] || shift
        unit=${1%.service}
        kind=active; [ "$action" != is-enabled ] || kind=enabled
        if [ -f "/test-state/$unit.$kind" ]; then echo "$kind"; exit 0; fi
        if [ "$kind" = enabled ]; then echo disabled; else echo inactive; fi
        exit 1
        ;;
    esac
    printf 'systemctl %s %s\n' "$action" "$*" >>/test-state/actions
    now=0
    for unit in "$@"; do
      case "$unit" in --now) now=1; continue ;; --*) continue ;; esac
      unit=${unit%.service}
      case "$action" in
        enable) touch "/test-state/$unit.enabled"; [ "$now" = 0 ] || touch "/test-state/$unit.active" ;;
        disable) rm -f "/test-state/$unit.enabled"; [ "$now" = 0 ] || rm -f "/test-state/$unit.active" ;;
        stop) rm -f "/test-state/$unit.active" ;;
        start|restart)
          [ ! -e /fail/server-start ] || { rm -f /fail/server-start; exit 1; }
          touch "/test-state/$unit.active"
          ;;
        *) echo "unexpected systemctl action: $action" >&2; exit 2 ;;
      esac
    done
    ;;
  ubus)
    case "$*" in
      *service*delete*) rm -f /test-state/router.transport /test-state/router.frpc /test-state/router.sync ;;
      *service*list*)
        printf '{"stargate-remote":{"instances":{'
        comma=''
        for instance in transport frpc sync; do
          [ -f "/test-state/router.$instance" ] || continue
          printf '%s"%s":{"running":true,"pid":123}' "$comma" "$instance"
          comma=,
        done
        printf '}}}\n'
        ;;
      *) echo '{}' ;;
    esac
    ;;
  jsonfilter)
    input=''; expression=''
    while [ "$#" -gt 0 ]; do
      case "$1" in -s) input=$2; shift 2 ;; -e) expression=$2; shift 2 ;; *) shift ;; esac
    done
    [ -n "$input" ] || input=$(cat)
    case "$expression" in
      *pid*)
        for instance in transport frpc sync; do
          case "$expression" in *"$instance"*) [ ! -e "/test-state/router.$instance" ] || echo 123; exit 0 ;; esac
        done
        ;;
      *running*)
        for instance in transport frpc sync; do
          case "$expression" in *"$instance"*) [ ! -e "/test-state/router.$instance" ] || echo true; exit 0 ;; esac
        done
        ;;
      *listen*) printf '%s' "$input" | /host/usr/bin/jq -r .listen ;;
      *) echo "unsupported jsonfilter expression: $expression" >&2; exit 2 ;;
    esac
    ;;
  curl) [ ! -e /fail/health ] ;;
  frpc|frps|frpc.next|frps.next|sing-box|sing-box.next)
    printf '%s %s\n' "$name" "$*" >>/test-state/commands
    [ ! -e /fail/verify ] || exit 1
    if [ "$name" = sing-box.next ] && [ -e /fail/remote-config ]; then
      case "$*" in *'/etc/stargate-remote/transport.json'*) exit 1 ;; esac
    fi
    case "${1:-}" in version|--version|-v) echo '0.71.0' ;; esac
    ;;
  stargate-remote|stargate-remote.next)
    printf 'agent %s\n' "$*" >>/test-state/commands
    operation=${1:-}; shift || true
    dir=/etc/stargate-remote
    health=0
    output=
    while [ "$#" -gt 0 ]; do
      case "$1" in --dir) dir=$2; shift 2 ;; --output) output=$2; shift 2 ;; --health) health=1; shift ;; *) shift ;; esac
    done
    case "$operation" in
      version) echo 'stargate-remote 1' ;;
      status) printf '{"schema":1,"device_id":"fixture","role":"provider"}\n' ;;
      server-init)
        mkdir -p "$dir"
        printf '{"schema":1,"listen":"127.0.0.1:17443"}\n' >"$dir/server.json"
        printf '{}\n' >"$dir/frps.json"
        printf 'fixture certificate\n' >"$dir/server.crt"
        ;;
      check-server) [ ! -e /fail/check-server ]; [ "$health" = 0 ] || [ ! -e /fail/health ] ;;
      prepare-server)
        [ ! -e /fail/prepare-server ] || exit 1
        [ -f "$dir/server.json" ] || exit 1
        printf '{"prepared":true}\n' >"$dir/frps.json"
        ;;
      enroll)
        [ ! -e /fail/enroll ] || exit 1
        mkdir -p "$dir"
        printf '{"schema":1,"device_id":"fixture","role":"provider"}\n' >"$dir/profile.json"
        printf '{}\n' >"$dir/transport.json"
        printf '{}\n' >"$dir/frpc.json"
        chmod 600 "$dir"/*.json
        ;;
      prepare)
        [ ! -e /fail/prepare ] || exit 1
        printf '{"prepared":true}\n' >"$dir/transport.json"
        printf '{"prepared":true}\n' >"$dir/frpc.json"
        ;;
      sync|watch) [ ! -e /fail/offline ] ;;
      proxy-export) printf 'anytls://fixture-only@fixture.invalid:443\n' >"$output"; chmod 600 "$output" ;;
      *) echo "unexpected agent operation: $operation" >&2; exit 2 ;;
    esac
    ;;
  *) echo "unexpected mock command: $name" >&2; exit 2 ;;
esac
