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

m = Map("stargate", translate("Rules"))
m.description = ui_text("Use Loyalsoldier rules with small user overrides. Rules are not bundled; update them explicitly before generating config.", "使用 Loyalsoldier 规则，并提供少量用户覆盖。规则不随包内置，需要先显式更新后再生成配置。")

local action = http.formvalue("stargate_rules_action")
if action == "update" or action == "status" then
  local command = action == "update" and "rules-update" or "rules-status"
  m.message = "<pre>" .. util.pcdata(sys.exec("/usr/share/stargate/stargate.sh " .. command .. " 2>&1")) .. "</pre>"
end

s = m:section(NamedSection, "rules", "rules", translate("Rule policy"))
s.anonymous = true

mode = s:option(ListValue, "mode", translate("Mode"))
mode:value("ruleset", translate("Loyalsoldier direct/proxy rules"))
mode:value("global_proxy", translate("Global proxy"))
mode:value("direct", translate("Direct only"))
mode.default = "ruleset"
mode.description = ui_text("Recommended: use upstream direct-list and proxy-list. User direct/proxy domains are matched before upstream rules.", "推荐：使用上游 direct-list 和 proxy-list。用户直连/代理域名优先于上游规则匹配。")

source = s:option(ListValue, "source", translate("Rule source"))
source:value("loyalsoldier", "Loyalsoldier/v2ray-rules-dat")
source.default = "loyalsoldier"
source:depends("mode", "ruleset")

source_base_url = s:option(Value, "source_base_url", translate("Source base URL"))
source_base_url.default = "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release"
source_base_url:depends("mode", "ruleset")

direct_rule_set = s:option(Value, "direct_rule_set", translate("Direct rule-set path"))
direct_rule_set.default = "/usr/share/stargate/rules/direct.json"
direct_rule_set:depends("mode", "ruleset")

proxy_rule_set = s:option(Value, "proxy_rule_set", translate("Proxy rule-set path"))
proxy_rule_set.default = "/usr/share/stargate/rules/proxy.json"
proxy_rule_set:depends("mode", "ruleset")

proxy_outbound = s:option(ListValue, "proxy_outbound", translate("Proxy outbound"))
proxy_outbound:value("anytls-out", translate("Proxy"))
proxy_outbound:value("direct", translate("Direct"))
proxy_outbound.default = "anytls-out"
proxy_outbound:depends("mode", "ruleset")

default_outbound = s:option(ListValue, "default_outbound", translate("Default outbound"))
default_outbound:value("direct", translate("Direct"))
default_outbound:value("anytls-out", translate("Proxy"))
default_outbound.default = "direct"

custom_direct_domains = s:option(TextValue, "custom_direct_domains", translate("User direct domains"))
custom_direct_domains.rows = 5
custom_direct_domains.wrap = "off"
custom_direct_domains.description = ui_text("One domain per line. These domains always go direct and take priority over upstream proxy rules.", "每行一个域名。这些域名始终直连，并优先于上游代理规则。")
custom_direct_domains:depends("mode", "ruleset")

custom_proxy_domains = s:option(TextValue, "custom_proxy_domains", translate("User proxy domains"))
custom_proxy_domains.rows = 5
custom_proxy_domains.wrap = "off"
custom_proxy_domains.description = ui_text("One domain per line. These domains always use the proxy outbound and take priority over upstream direct rules.", "每行一个域名。这些域名始终使用代理出站，并优先于上游直连规则。")
custom_proxy_domains:depends("mode", "ruleset")

actions = s:option(DummyValue, "_rules_actions", translate("Rule actions"))
actions.rawhtml = true
function actions.cfgvalue()
  local status = trim(sys.exec("/usr/share/stargate/stargate.sh rules-status 2>/dev/null"))
  local base = dispatcher.build_url("admin", "services", "stargate", "rules")
  return table.concat({
    '<style>',
    '.stargate-rule-actions{display:grid;gap:10px;max-width:920px}',
    '.stargate-rule-action-row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}',
    '.stargate-rule-status{white-space:pre-wrap;font-size:12px;opacity:.78;padding:10px;border-top:1px solid rgba(127,127,127,.18)}',
    '</style>',
    '<div class="stargate-rule-actions">',
    '<div class="stargate-rule-action-row">',
    '<input class="cbi-button cbi-button-apply" type="button" value="' .. ui_text("Update Loyalsoldier rules", "更新 Loyalsoldier 规则") .. '" onclick="location.href=\'' .. base .. '?stargate_rules_action=update\'" />',
    '<input class="cbi-button" type="button" value="' .. ui_text("Refresh status", "刷新状态") .. '" onclick="location.href=\'' .. base .. '?stargate_rules_action=status\'" />',
    '</div>',
    '<div class="stargate-rule-status">' .. util.pcdata(status) .. '</div>',
    '</div>'
  }, "\n")
end
actions:depends("mode", "ruleset")

private_direct = s:option(Flag, "private_direct", translate("Private IP direct"))
private_direct.default = "1"
private_direct.rmempty = false

block_quic = s:option(Flag, "block_quic", translate("Block QUIC"))
block_quic.default = "0"
block_quic.rmempty = false

return m
