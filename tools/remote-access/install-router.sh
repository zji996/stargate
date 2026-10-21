#!/bin/sh
set -eu
base=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
bundle=${1:?usage: install-router.sh BUNDLE [ENROLLMENT_FILE]}
link=${2:-}
. "$base/installer-common.sh"
sg_begin router
command -v ubus >/dev/null
command -v jsonfilter >/dev/null
[ -x /usr/bin/sing-box ] || { echo 'system sing-box is required' >&2; exit 1; }
[ -x "$bundle/stargate-remote" ] && [ -x "$bundle/frpc" ] || exit 1
sh -n "$base/services/stargate-remote.init"
sh -n "$base/rollback-router.sh"
"$bundle/stargate-remote" version >/dev/null
"$bundle/frpc" --version >/dev/null
upgrade=0
if [ -f /etc/stargate-remote/profile.json ]; then
  upgrade=1
  "$bundle/stargate-remote" status --dir /etc/stargate-remote >/dev/null
  /usr/bin/sing-box check -c /etc/stargate-remote/transport.json
  "$bundle/frpc" verify -c /etc/stargate-remote/frpc.json
else
  if [ -f /etc/stargate-remote/installed ] && [ "$(cat /etc/stargate-remote/installed)" = stargate-remote ]; then
    :
  else
    for path in /etc/stargate-remote /usr/bin/stargate-remote /usr/bin/frpc /etc/init.d/stargate-remote; do
      [ ! -e "$path" ] || { echo "Existing unmanaged or incomplete component: $path" >&2; exit 1; }
    done
  fi
  [ -z "$link" ] || [ -f "$link" ] || { echo 'Enrollment file does not exist.' >&2; exit 1; }
fi
[ "$upgrade" = 0 ] || sg_acquire_config_lock
sg_backup_files
echo 0 >"$backup/enabled"
echo 0 >"$backup/running"
if [ -x /etc/init.d/stargate-remote ]; then
  /etc/init.d/stargate-remote enabled && echo 1 >"$backup/enabled" || true
  /etc/init.d/stargate-remote running && echo 1 >"$backup/running" || true
fi
sg_seal_backup
sg_transaction_ready
if [ -x /etc/init.d/stargate-remote ]; then /etc/init.d/stargate-remote stop; fi
sg_release_config_lock
cp "$bundle/stargate-remote" /usr/bin/stargate-remote.next
cp "$bundle/frpc" /usr/bin/frpc.next
chmod 755 /usr/bin/stargate-remote.next /usr/bin/frpc.next
mv /usr/bin/stargate-remote.next /usr/bin/stargate-remote
mv /usr/bin/frpc.next /usr/bin/frpc
mkdir -p /etc/stargate-remote
chmod 700 /etc/stargate-remote
printf 'stargate-remote\n' >/etc/stargate-remote/installed
chmod 600 /etc/stargate-remote/installed
if [ "$upgrade" = 0 ] && [ -n "$link" ]; then
  recovery=$(mktemp -d /root/stargate-remote-enrollment-XXXXXX)
  STARGATE_REMOTE_LOCK_HELD=1 /usr/bin/stargate-remote enroll --dir /etc/stargate-remote --link-file "$link"
  cp /etc/stargate-remote/profile.json "$recovery/profile.json"
  chmod 700 "$recovery"
  chmod 600 "$recovery/profile.json"
  printf 'Enrollment recovery copy (retained if installation fails): %s\n' "$recovery"
fi
cp "$base/services/stargate-remote.init" /etc/init.d/stargate-remote
chmod 755 /etc/init.d/stargate-remote
if [ ! -f /etc/stargate-remote/profile.json ]; then
  /etc/init.d/stargate-remote disable
  sg_commit
  printf 'Remote addon installed in standby. Import a Stargate link in LuCI. Backup: %s\n' "$backup"
  exit 0
fi
STARGATE_REMOTE_LOCK_HELD=1 /usr/bin/stargate-remote prepare --dir /etc/stargate-remote
if [ "$upgrade" = 0 ] || [ "$(cat "$backup/enabled")" = 1 ]; then
  /etc/init.d/stargate-remote enable
else
  /etc/init.d/stargate-remote disable
fi
if [ "$upgrade" = 0 ] || [ "$(cat "$backup/running")" = 1 ]; then
  /etc/init.d/stargate-remote start
  ready=0
  for attempt in 1 2 3 4 5; do
    state=$(ubus call service list '{"name":"stargate-remote"}')
    ready=1
    for instance in transport frpc sync; do
      running=$(printf '%s\n' "$state" | jsonfilter -e "@[\"stargate-remote\"].instances.$instance.running")
      [ "$running" = true ] || ready=0
    done
    [ "$ready" = 0 ] || break
    sleep 1
  done
  [ "$ready" = 1 ] || { echo 'Not all remote-access processes started.' >&2; exit 1; }
  if ! STARGATE_REMOTE_LOCK_HELD=1 /usr/bin/stargate-remote sync --dir /etc/stargate-remote; then
    if [ "$upgrade" = 0 ]; then exit 1; fi
    echo 'Installed using stored configuration; remote sync will retry automatically.' >&2
  fi
fi
sg_commit
[ -z "${recovery:-}" ] || rm -rf "$recovery"
printf 'Remote addon installed. Backup and rollback: %s\n' "$backup"
