#!/bin/sh
set -eu
bundle=${1:?usage: install-luci.sh LUCI_FILES_BUNDLE}
[ "$(id -u)" = 0 ] || exit 1
base=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$base/installer-common.sh"
sg_begin luci
for file in controller.lua remote.lua remote.htm menu.json stargate.zh-cn.lmo remote-control.sh stargate.sh maintenance.sh; do
  [ -f "$bundle/$file" ] || { echo "missing bundle file: $file" >&2; exit 1; }
done
sh -n "$bundle/remote-control.sh"
sh -n "$bundle/stargate.sh"
sh -n "$bundle/maintenance.sh"
lua - "$bundle" <<'LUA'
local base = arg[1]
assert(loadfile(base .. "/controller.lua"))
assert(loadfile(base .. "/remote.lua"))
local file = assert(io.open(base .. "/menu.json", "r"))
local menu = assert(require("luci.jsonc").parse(file:read("*a")))
file:close()
local entry = assert(menu["admin/services/stargate/remote"])
assert(entry.action and entry.action.type == "cbi" and entry.action.path == "stargate/client/remote")
assert(menu["admin/services/stargate"] and menu["admin/services/stargate/overview"])
local template, _, err = require("luci.template.parser").parse(base .. "/remote.htm")
assert(template, err)
LUA
[ -f "$base/rollback-luci.sh" ] || { echo 'missing rollback-luci.sh' >&2; exit 1; }
sh -n "$base/rollback-luci.sh"
sg_backup_files
sg_seal_backup
sg_transaction_ready
mkdir -p /usr/lib/lua/luci/view/stargate /usr/lib/lua/luci/model/cbi/stargate/client /usr/share/luci/menu.d /usr/lib/lua/luci/i18n /usr/share/stargate/lib
cp "$bundle/controller.lua" /usr/lib/lua/luci/controller/stargate.lua
cp "$bundle/remote.lua" /usr/lib/lua/luci/model/cbi/stargate/client/remote.lua
cp "$bundle/remote.htm" /usr/lib/lua/luci/view/stargate/remote.htm
cp "$bundle/menu.json" /usr/share/luci/menu.d/luci-app-stargate.json
cp "$bundle/stargate.zh-cn.lmo" /usr/lib/lua/luci/i18n/stargate.zh-cn.lmo
cp "$bundle/remote-control.sh" /usr/share/stargate/remote-control.sh
cp "$bundle/stargate.sh" /usr/share/stargate/stargate.sh
cp "$bundle/maintenance.sh" /usr/share/stargate/lib/maintenance.sh
chmod 755 /usr/share/stargate/remote-control.sh /usr/share/stargate/stargate.sh
if ! lua -e 'assert(loadfile("/usr/lib/lua/luci/controller/stargate.lua")); assert(loadfile("/usr/lib/lua/luci/model/cbi/stargate/client/remote.lua"))'; then
  echo "UI validation failed; restoring existing files from $backup" >&2
  exit 1
fi
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache* /tmp/luci-cache /tmp/rpcdcache
printf 'Remote-access LuCI files installed. Backup: %s\n' "$backup"
sg_commit
