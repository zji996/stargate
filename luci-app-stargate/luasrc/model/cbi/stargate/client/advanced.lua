local sys = require "luci.sys"
local http = require "luci.http"
local util = require "luci.util"
local dispatcher = require "luci.dispatcher"
local common = require "luci.model.stargate.common"

local trim = common.trim
local ui_text = common.ui_text

m = Map("stargate", ui_text("Advanced", "高级"))
common.prepare_map(m)
m.description = ui_text("Forwarding and system integration settings for transparent proxy.", "透明代理的转发和系统集成设置。")

local action = common.action("stargate_advanced_action")
if action == "apply-forwarding" then
  m.message = trim(sys.exec("/usr/share/stargate/stargate.sh firewall-apply 2>&1"))
elseif action == "clean-forwarding" then
  m.message = trim(sys.exec("/usr/share/stargate/stargate.sh firewall-clean 2>&1"))
end

s = m:section(NamedSection, "inbound", "inbound", ui_text("Forwarding", "转发配置"))
s.anonymous = true

actions = s:option(DummyValue, "_forwarding_actions", ui_text("Forwarding rules", "转发规则"))
actions.rawhtml = true
function actions.cfgvalue()
  local base = dispatcher.build_url("admin", "services", "stargate", "advanced")
  local status = trim(sys.exec("/usr/share/stargate/stargate.sh firewall-status 2>/dev/null"))
  if status == "" then
    status = ui_text("No firewall backend status.", "没有防火墙后端状态。")
  end
  return table.concat({
    '<style>',
    '#cbi-stargate-inbound-_forwarding_actions{display:block;max-width:960px;margin:0 auto;padding:0;border:0}',
    '#cbi-stargate-inbound-_forwarding_actions>.cbi-value-title{display:none}',
    '#cbi-stargate-inbound-_forwarding_actions>.cbi-value-field{display:block;margin:0;width:100%}',
    '.stargate-forwarding-card{display:grid;grid-template-columns:1fr auto;gap:16px;align-items:center;padding:16px;border:1px solid rgba(140,140,140,.42);border-radius:6px;background:rgba(127,127,127,.05)}',
    '.stargate-forwarding-status{font-size:12px;line-height:1.55;white-space:pre-wrap;opacity:.82}',
    '.stargate-forwarding-actions{display:flex;gap:10px;flex-wrap:wrap;justify-content:flex-end}',
    '.stargate-forwarding-note{font-size:12px;line-height:1.5;opacity:.72;margin-top:8px}',
    '@media(max-width:720px){.stargate-forwarding-card{grid-template-columns:1fr}.stargate-forwarding-actions{justify-content:flex-start}}',
    '</style>',
    '<div class="stargate-forwarding-card">',
    '<div>',
    '<div class="stargate-forwarding-status">' .. util.pcdata(status) .. '</div>',
    '<div class="stargate-forwarding-note">' .. ui_text("Applies or removes only Stargate-owned transparent proxy forwarding rules. Backend is selected automatically: nftables first, iptables fallback.", "只应用或清理 Stargate 自己的透明代理转发规则。后端自动选择：优先 nftables，缺失时回退 iptables。") .. '</div>',
    '</div>',
    '<div class="stargate-forwarding-actions">',
    '<button type="button" class="cbi-button cbi-button-apply" data-field="stargate_advanced_action" data-stargate-action="apply-forwarding">' .. ui_text("Apply transparent forwarding", "应用透明代理转发") .. '</button>',
    '<button type="button" class="cbi-button" data-field="stargate_advanced_action" data-stargate-action="clean-forwarding" data-confirm="' .. ui_text("Remove forwarding? Managed traffic will no longer use the proxy.", "清理转发后，受管流量将不再经过代理，继续？") .. '">' .. ui_text("Clean Stargate forwarding", "清理 Stargate 转发") .. '</button>',
    '</div>',
    '</div>'
  }, "\n")
end

local port = s:option(Value, "transparent_port", ui_text("Transparent port", "透明代理端口"))
port.default = "12345"
port.datatype = "port"
port.rmempty = false
local iface = s:option(Value, "netbird_interface", ui_text("NetBird interface", "NetBird 接口"))
iface.default = "wt0"
iface.rmempty = false

return m
