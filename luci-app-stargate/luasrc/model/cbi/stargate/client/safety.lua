local sys = require "luci.sys"
local util = require "luci.util"

m = Map("stargate", translate("Safety"))

s = m:section(NamedSection, "safety", "safety", translate("System changes"))
s.anonymous = true

backup_on_apply = s:option(Flag, "backup_on_apply", translate("Backup before apply"))
backup_on_apply.default = "1"
backup_on_apply.rmempty = false

transparent_proxy = s:option(Flag, "transparent_proxy", translate("Transparent proxy"))
transparent_proxy.default = "0"
transparent_proxy.rmempty = false

manage_firewall = s:option(Flag, "manage_firewall", translate("Manage firewall"))
manage_firewall.default = "0"
manage_firewall.rmempty = false

manage_dnsmasq = s:option(Flag, "manage_dnsmasq", translate("Manage dnsmasq"))
manage_dnsmasq.default = "0"
manage_dnsmasq.rmempty = false

diag = s:option(DummyValue, "_diagnostics", translate("Diagnostics"))
diag.rawhtml = true
function diag.cfgvalue()
  local logs = sys.exec("/usr/share/stargate/stargate.sh logs 2>/dev/null")
  if logs == "" then
    logs = translate("No logs")
  end
  return "<pre style=\"white-space: pre-wrap\">" .. util.pcdata(logs) .. "</pre>"
end

return m
