#!/bin/sh
set -eu
base=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
backup=${1:?backup directory required}
. "$base/installer-common.sh"
sg_begin router
sg_validate_backup
if [ -x /etc/init.d/stargate-remote ]; then
  /etc/init.d/stargate-remote stop || true
  /etc/init.d/stargate-remote disable || true
fi
# procd must also stop instances when the replaced init script cannot execute.
ubus call service delete '{"name":"stargate-remote"}' >/dev/null 2>&1 || true
rm -f /etc/rc.d/*stargate-remote
rm -rf /etc/stargate-remote
rm -f /usr/bin/stargate-remote /usr/bin/frpc /usr/bin/stargate-remote.next /usr/bin/frpc.next /etc/init.d/stargate-remote
tar -C / -xzf "$backup/files.tar.gz"
if [ -x /etc/init.d/stargate-remote ]; then
  if [ "$(cat "$backup/enabled")" = 1 ]; then /etc/init.d/stargate-remote enable; else /etc/init.d/stargate-remote disable; fi
  [ "$(cat "$backup/running")" = 0 ] || /etc/init.d/stargate-remote start
fi
echo 'Remote addon restored to its pre-install state.'
