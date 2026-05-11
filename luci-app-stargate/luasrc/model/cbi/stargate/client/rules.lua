local sys = require "luci.sys"
local http = require "luci.http"
local util = require "luci.util"
local dispatcher = require "luci.dispatcher"

local function trim(value)
  return (value or ""):gsub("%s+$", "")
end

local function ui_text(en, zh)
  local lang = trim(sys.exec("uci -q get luci.main.lang 2>/dev/null || echo auto"))
  if lang == "zh_cn" or lang == "zh-cn" or lang == "zh" or lang == "auto" then
    return zh
  end
  return en
end

local function rule_status_html(message)
  local status = trim(sys.exec("/usr/share/stargate/stargate.sh rules-status 2>/dev/null"))
  local parts = {}
  if message and message ~= "" then
    parts[#parts + 1] = '<div class="stargate-rule-ok">' .. util.pcdata(message) .. '</div>'
  end
  for line in status:gmatch("[^\r\n]+") do
    local key, value = line:match("^([^:]+):%s*(.*)$")
    if key and value then
      parts[#parts + 1] = '<div class="stargate-rule-status-row"><span>' .. util.pcdata(key) .. '</span><strong>' .. util.pcdata(value) .. '</strong></div>'
    end
  end
  if #parts == 0 then
    parts[#parts + 1] = '<div class="stargate-rule-status-row"><span>' .. ui_text("Rule files", "规则文件") .. '</span><strong>' .. ui_text("Not updated", "未更新") .. '</strong></div>'
  end
  return table.concat(parts, "\n")
end

m = Map("stargate", translate("Rules"))
m.description = ui_text("Use Loyalsoldier as the base rule source. Pick a blacklist or whitelist routing mode, then add only the few domains you want to override.", "以 Loyalsoldier 作为基础规则源。选择黑名单或白名单模式，只额外填写少量需要覆盖的域名。")

local message = nil
local action = http.formvalue("stargate_rules_action")
if action == "update" then
  sys.exec("/usr/share/stargate/stargate.sh rules-update-start >/dev/null 2>&1")
  message = ui_text("Rule update started. Refresh status in a moment.", "规则更新已开始，稍后刷新状态查看结果。")
elseif action == "status" then
  message = ui_text("Rule status refreshed.", "规则状态已刷新。")
end

s = m:section(NamedSection, "rules", "rules", translate("Rule policy"))
s.anonymous = true

mode = s:option(ListValue, "mode", translate("Mode"))
mode:value("blacklist", translate("Blacklist mode"))
mode:value("whitelist", translate("Whitelist mode"))
mode:value("global_proxy", translate("Global proxy"))
mode:value("direct", translate("Direct only"))
mode.default = "blacklist"
mode.description = ui_text("Blacklist: default direct, listed proxy domains use the node. Whitelist: default proxy, listed direct domains go direct.", "黑名单：默认直连，代理列表域名走节点。白名单：默认代理，直连列表域名走直连。")

source = s:option(ListValue, "source", translate("Rule source"))
source:value("loyalsoldier", "Loyalsoldier/v2ray-rules-dat")
source.default = "loyalsoldier"
source:depends("mode", "blacklist")
source:depends("mode", "whitelist")

source_base_url = s:option(Value, "source_base_url", translate("Source base URL"))
source_base_url.default = "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release"
source_base_url:depends("mode", "blacklist")
source_base_url:depends("mode", "whitelist")

direct_rule_set = s:option(Value, "direct_rule_set", translate("Direct rule-set path"))
direct_rule_set.default = "/usr/share/stargate/rules/direct.json"
direct_rule_set:depends("mode", "blacklist")
direct_rule_set:depends("mode", "whitelist")

proxy_rule_set = s:option(Value, "proxy_rule_set", translate("Proxy rule-set path"))
proxy_rule_set.default = "/usr/share/stargate/rules/proxy.json"
proxy_rule_set:depends("mode", "blacklist")
proxy_rule_set:depends("mode", "whitelist")

custom_direct_domains = s:option(TextValue, "custom_direct_domains", translate("User direct domains"))
custom_direct_domains.rows = 5
custom_direct_domains.wrap = "off"
custom_direct_domains.description = ui_text("One domain per line. These domains always go direct and take priority over the base rules.", "每行一个域名。这些域名始终直连，并优先于基础规则。")
custom_direct_domains:depends("mode", "blacklist")
custom_direct_domains:depends("mode", "whitelist")

custom_proxy_domains = s:option(TextValue, "custom_proxy_domains", translate("User proxy domains"))
custom_proxy_domains.rows = 5
custom_proxy_domains.wrap = "off"
custom_proxy_domains.description = ui_text("One domain per line. These domains always use the node and take priority over the base rules.", "每行一个域名。这些域名始终走节点，并优先于基础规则。")
custom_proxy_domains:depends("mode", "blacklist")
custom_proxy_domains:depends("mode", "whitelist")

actions = s:option(DummyValue, "_rules_actions", translate("Rule actions"))
actions.rawhtml = true
function actions.cfgvalue()
  local base = dispatcher.build_url("admin", "services", "stargate", "rules")
  return table.concat({
    '<style>',
    '.stargate-rule-actions{display:grid;gap:12px;max-width:920px}',
    '.stargate-rule-action-row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}',
    '.stargate-rule-status{display:grid;gap:8px;padding:12px;border-top:1px solid rgba(127,127,127,.18)}',
    '.stargate-rule-status-row{display:flex;justify-content:space-between;gap:16px;font-size:13px;line-height:1.45}',
    '.stargate-rule-status-row span{opacity:.72}',
    '.stargate-rule-status-row strong{font-weight:600;text-align:right}',
    '.stargate-rule-ok{padding:8px 10px;border-radius:6px;background:rgba(46,160,67,.16);color:#9fd49f}',
    '</style>',
    '<div class="stargate-rule-actions">',
    '<div class="stargate-rule-action-row">',
    '<input class="cbi-button cbi-button-apply" type="button" value="' .. ui_text("Update base rules", "更新基础规则") .. '" onclick="location.href=\'' .. base .. '?stargate_rules_action=update\'" />',
    '<input class="cbi-button" type="button" value="' .. ui_text("Refresh status", "刷新状态") .. '" onclick="location.href=\'' .. base .. '?stargate_rules_action=status\'" />',
    '</div>',
    '<div class="stargate-rule-status">' .. rule_status_html(message) .. '</div>',
    '</div>'
  }, "\n")
end
actions:depends("mode", "blacklist")
actions:depends("mode", "whitelist")

private_direct = s:option(Flag, "private_direct", translate("Private IP direct"))
private_direct.default = "1"
private_direct.rmempty = false

block_quic = s:option(Flag, "block_quic", translate("Block QUIC"))
block_quic.default = "0"
block_quic.rmempty = false
block_quic.description = ui_text("Reject UDP/443 so browsers and apps fall back from HTTP/3/QUIC to TCP/TLS. This can make proxy routing more predictable, but may reduce speed for services that benefit from QUIC.", "拒绝 UDP/443，让浏览器和应用从 HTTP/3/QUIC 回退到 TCP/TLS。这样代理分流更可预测，但可能降低依赖 QUIC 的服务速度。")

return m
