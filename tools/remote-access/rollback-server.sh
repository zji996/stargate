#!/bin/sh
set -eu
base=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
backup=${1:?backup directory required}
. "$base/installer-common.sh"
sg_begin server
sg_validate_backup
systemctl disable --now stargate-remote-frps stargate-remote-controller 2>/dev/null || true
rm -rf /etc/stargate-remote /usr/local/lib/stargate-remote
rm -f /etc/systemd/system/stargate-remote-controller.service /etc/systemd/system/stargate-remote-frps.service
tar -C / -xzf "$backup/files.tar.gz"
systemctl daemon-reload
if [ -f /etc/systemd/system/stargate-remote-controller.service ]; then
  sg_restore_server_state
fi
echo 'Remote addon restored to its pre-install state.'
