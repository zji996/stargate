#!/bin/sh
set -eu
base=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
bundle=${1:?usage: install-server.sh BUNDLE [NODE_JSON]}
node=${2:-}
. "$base/installer-common.sh"
sg_begin server
[ -x "$bundle/stargate-remote" ] && [ -x "$bundle/frps" ] || exit 1
command -v systemctl >/dev/null
sh -n "$base/rollback-server.sh"
for service in controller frps; do
  [ -s "$base/services/stargate-remote-$service.service" ] || exit 1
done
"$bundle/stargate-remote" version >/dev/null
upgrade=0
if [ -f /etc/stargate-remote/server.json ]; then
  upgrade=1
  "$bundle/stargate-remote" check-server --dir /etc/stargate-remote
  "$bundle/frps" verify -c /etc/stargate-remote/frps.json
else
  [ -n "$node" ] && [ -f "$node" ] || { echo 'Node JSON is required for first installation.' >&2; exit 1; }
  for path in /etc/stargate-remote /usr/local/lib/stargate-remote /etc/systemd/system/stargate-remote-controller.service /etc/systemd/system/stargate-remote-frps.service; do
    [ ! -e "$path" ] || { echo "Existing unmanaged or incomplete component: $path" >&2; exit 1; }
  done
fi
sg_backup_files
for service in controller frps; do
  systemctl is-active "stargate-remote-$service" >"$backup/$service.active" 2>/dev/null || true
  systemctl is-enabled "stargate-remote-$service" >"$backup/$service.enabled" 2>/dev/null || true
  case "$(cat "$backup/$service.enabled")" in
    enabled|enabled-runtime|disabled|'') ;;
    *) echo 'Masked or unsupported units must be resolved before installation.' >&2; exit 1 ;;
  esac
done
sg_seal_backup
sg_transaction_ready
getent passwd stargate-remote >/dev/null || useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin stargate-remote
install -d -m 755 /usr/local/lib/stargate-remote
install -m 755 "$bundle/stargate-remote" /usr/local/lib/stargate-remote/stargate-remote.next
install -m 755 "$bundle/frps" /usr/local/lib/stargate-remote/frps.next
if [ "$upgrade" = 0 ]; then
  /usr/local/lib/stargate-remote/stargate-remote.next server-init --dir /etc/stargate-remote --node-file "$node"
fi
/usr/local/lib/stargate-remote/stargate-remote.next check-server --dir /etc/stargate-remote
/usr/local/lib/stargate-remote/frps.next verify -c /etc/stargate-remote/frps.json
if [ "$upgrade" = 1 ]; then systemctl stop stargate-remote-frps stargate-remote-controller; fi
/usr/local/lib/stargate-remote/stargate-remote.next prepare-server --dir /etc/stargate-remote
/usr/local/lib/stargate-remote/frps.next verify -c /etc/stargate-remote/frps.json
mv /usr/local/lib/stargate-remote/stargate-remote.next /usr/local/lib/stargate-remote/stargate-remote
mv /usr/local/lib/stargate-remote/frps.next /usr/local/lib/stargate-remote/frps
chown -R stargate-remote:stargate-remote /etc/stargate-remote
chmod 700 /etc/stargate-remote
install -m 644 "$base/services/stargate-remote-controller.service" /etc/systemd/system/stargate-remote-controller.service
install -m 644 "$base/services/stargate-remote-frps.service" /etc/systemd/system/stargate-remote-frps.service
systemctl daemon-reload
check_controller=1
check_frps=1
if [ "$upgrade" = 1 ]; then
  sg_restore_server_state
  [ "$(cat "$backup/controller.active")" = active ] || check_controller=0
  [ "$(cat "$backup/frps.active")" = active ] || check_frps=0
else
  systemctl start stargate-remote-controller stargate-remote-frps
fi
ready=0
for attempt in 1 2 3 4 5; do
  if { [ "$check_controller" = 0 ] || {
      systemctl is-active --quiet stargate-remote-controller &&
      /usr/local/lib/stargate-remote/stargate-remote check-server --dir /etc/stargate-remote --health;
    }; } && { [ "$check_frps" = 0 ] || systemctl is-active --quiet stargate-remote-frps; }; then
    ready=1
    break
  fi
  sleep 1
done
[ "$ready" = 1 ] || { echo 'Remote server health check failed.' >&2; exit 1; }
if [ "$upgrade" = 0 ]; then
  systemctl enable stargate-remote-controller stargate-remote-frps
fi
sg_commit
printf 'Remote addon installed. Backup and rollback: %s\n' "$backup"
