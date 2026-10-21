#!/bin/sh
set -eu
base=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
backup=${1:?backup directory required}
. "$base/installer-common.sh"
sg_begin luci
sg_validate_backup
for path in usr/lib/lua/luci/controller/stargate.lua usr/lib/lua/luci/model/cbi/stargate/client/remote.lua usr/lib/lua/luci/view/stargate/remote.htm usr/share/luci/menu.d/luci-app-stargate.json usr/lib/lua/luci/i18n/stargate.zh-cn.lmo usr/share/stargate/remote-control.sh usr/share/stargate/stargate.sh usr/share/stargate/lib/maintenance.sh; do
  rm -f "/$path"
done
tar -C / -xzf "$backup/files.tar.gz"
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache* /tmp/luci-cache /tmp/rpcdcache
echo 'Remote-access LuCI files restored to their pre-install state.'
