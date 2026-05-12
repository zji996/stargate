local sys = require "luci.sys"
local http = require "luci.http"
local util = require "luci.util"
local dispatcher = require "luci.dispatcher"
local common = require "luci.model.stargate.common"

local trim = common.trim
local ui_text = common.ui_text
local rule_modes = { "blacklist", "whitelist" }

local function rule_status_html(message)
  local status = trim(sys.exec("/usr/share/stargate/stargate.sh rules-status 2>/dev/null"))
  local parts = {}
  if message and message ~= "" then
    parts[#parts + 1] = '<div class="stargate-rule-ok">' .. common.pc(message) .. '</div>'
  end
  local status_html = common.status_rows_html(common.status_rows(status), "stargate-rule-status-row")
  if status_html ~= "" then
    parts[#parts + 1] = status_html
  end
  if #parts == 0 then
    parts[#parts + 1] = '<div class="stargate-rule-status-row"><span>' .. ui_text("Rule files", "规则文件") .. '</span><strong>' .. ui_text("Not updated", "未更新") .. '</strong></div>'
  end
  return table.concat(parts, "\n")
end

local function rule_rows_html(rows)
  if #rows == 0 then
    return ""
  end
  return '<div class="stargate-rule-test-result">' .. common.status_rows_html(rows, "stargate-rule-status-row") .. '</div>'
end

local function rule_test_html(output)
  return rule_rows_html(common.status_rows(output))
end

local function depends_rule_mode(option)
  common.depends_any(option, "mode", rule_modes)
end

m = Map("stargate", translate("Rules"))
m.description = ui_text("Use Loyalsoldier clash-rules for domain rules and sing-box GeoIP rule-sets for IP CIDR routing; user overrides are only for exceptions.", "域名规则使用 Loyalsoldier clash-rules，IP 分流使用 sing-box GeoIP rule-set；用户规则只用于少量例外覆盖。")

local message = nil
local test_output = nil
local test_target = trim(http.formvalue("stargate_rules_target") or "")
local action = http.formvalue("stargate_rules_action")
if action == "update" then
  sys.exec("/usr/share/stargate/stargate.sh rules-update-start >/dev/null 2>&1")
  message = ui_text("Rule update started. Refresh status in a moment.", "规则更新已开始，稍后刷新状态查看结果。")
elseif action == "status" then
  message = ui_text("Rule status refreshed.", "规则状态已刷新。")
elseif action == "test" and test_target ~= "" then
  test_output = sys.exec("/usr/share/stargate/stargate.sh rules-test " .. util.shellquote(test_target) .. " 2>&1")
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
source:value("loyalsoldier", "Loyalsoldier/clash-rules")
source.default = "loyalsoldier"
depends_rule_mode(source)

source_base_url = s:option(Value, "source_base_url", translate("Source base URL"))
source_base_url.default = "https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release"
depends_rule_mode(source_base_url)

geoip_base_url = s:option(Value, "geoip_base_url", translate("GeoIP source base URL"))
geoip_base_url.default = "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip"
depends_rule_mode(geoip_base_url)

direct_rule_set = s:option(Value, "direct_rule_set", translate("Direct rule-set path"))
direct_rule_set.default = "/usr/share/stargate/rules/direct.json"
depends_rule_mode(direct_rule_set)

proxy_rule_set = s:option(Value, "proxy_rule_set", translate("Proxy rule-set path"))
proxy_rule_set.default = "/usr/share/stargate/rules/proxy.json"
depends_rule_mode(proxy_rule_set)

geoip_direct_rule_set = s:option(Value, "geoip_direct_rule_set", translate("Direct GeoIP rule-set path"))
geoip_direct_rule_set.default = "/usr/share/stargate/rules/geoip-cn.srs"
depends_rule_mode(geoip_direct_rule_set)

geoip_proxy_rule_sets = s:option(Value, "geoip_proxy_rule_sets", translate("Proxy GeoIP rule-set paths"))
geoip_proxy_rule_sets.default = "/usr/share/stargate/rules/geoip-google.srs /usr/share/stargate/rules/geoip-facebook.srs /usr/share/stargate/rules/geoip-twitter.srs /usr/share/stargate/rules/geoip-telegram.srs"
depends_rule_mode(geoip_proxy_rule_sets)

geoip_proxy_extra_cidrs = s:option(TextValue, "geoip_proxy_extra_cidrs", translate("Proxy GeoIP supplement CIDR"))
geoip_proxy_extra_cidrs.default = "104.244.43.0/24"
geoip_proxy_extra_cidrs.rows = 2
geoip_proxy_extra_cidrs.wrap = "off"
depends_rule_mode(geoip_proxy_extra_cidrs)

custom_direct_domains = s:option(TextValue, "custom_direct_domains", translate("User direct domains"))
custom_direct_domains.rows = 5
custom_direct_domains.wrap = "off"
custom_direct_domains.description = ui_text("One domain per line. These domains always go direct and take priority over the base rules.", "每行一个域名。这些域名始终直连，并优先于基础规则。")
depends_rule_mode(custom_direct_domains)

custom_proxy_domains = s:option(TextValue, "custom_proxy_domains", translate("User proxy domains"))
custom_proxy_domains.rows = 5
custom_proxy_domains.wrap = "off"
custom_proxy_domains.description = ui_text("One domain per line. These domains always use the node and take priority over the base rules.", "每行一个域名。这些域名始终走节点，并优先于基础规则。")
depends_rule_mode(custom_proxy_domains)

custom_direct_ips = s:option(TextValue, "custom_direct_ips", translate("User direct IP/CIDR"))
custom_direct_ips.rows = 4
custom_direct_ips.wrap = "off"
custom_direct_ips.description = ui_text("Optional. Base GeoIP-style CIDR rules already cover common direct IP ranges; add only exceptions.", "可选。基础 CIDR 规则已覆盖常见直连 IP 段，只在有例外时填写。")
depends_rule_mode(custom_direct_ips)

custom_proxy_ips = s:option(TextValue, "custom_proxy_ips", translate("User proxy IP/CIDR"))
custom_proxy_ips.rows = 4
custom_proxy_ips.wrap = "off"
custom_proxy_ips.description = ui_text("Optional. Base CIDR rules already cover common proxy IP ranges such as Telegram; add only exceptions.", "可选。基础 CIDR 规则已覆盖 Telegram 等常见代理 IP 段，只在有例外时填写。")
depends_rule_mode(custom_proxy_ips)

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
    '.stargate-rule-test{display:grid;grid-template-columns:minmax(220px,1fr) auto;gap:10px;align-items:center}',
    '.stargate-rule-test-result{grid-column:1/-1;display:grid;gap:8px;padding:12px;border:1px solid rgba(127,127,127,.18);border-radius:6px}',
    '@media(max-width:720px){.stargate-rule-test{grid-template-columns:1fr}}',
    '</style>',
    '<div class="stargate-rule-actions">',
    '<div class="stargate-rule-action-row">',
    '<input class="cbi-button cbi-button-apply" type="button" value="' .. ui_text("Update base rules", "更新基础规则") .. '" onclick="location.href=\'' .. base .. '?stargate_rules_action=update\'" />',
    '<input class="cbi-button" type="button" value="' .. ui_text("Refresh status", "刷新状态") .. '" onclick="location.href=\'' .. base .. '?stargate_rules_action=status\'" />',
    '</div>',
    '<div class="stargate-rule-status">' .. rule_status_html(message) .. '</div>',
    '<div class="stargate-rule-test">',
    '<input id="stargate-rules-target" class="cbi-input-text" type="text" value="' .. common.pc(test_target) .. '" placeholder="' .. ui_text("Domain or IP", "域名或 IP") .. '" />',
    '<input class="cbi-button" type="button" value="' .. ui_text("Test policy", "测试策略") .. '" onclick="stargateRulesTestPolicy()" />',
    rule_test_html(test_output),
    '</div>',
    '</div>',
    '<script type="text/javascript">',
    '//<![CDATA[',
    'function stargateRulesHtml(s){return String(s||"").replace(/[&<>"\']/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;","\\"":"&quot;","\'":"&#39;"}[c];});}',
    'function stargateRulesRows(text){var html="";String(text||"").split(/\\r?\\n/).forEach(function(line){var m=line.match(/^([^:]+):\\s*(.*)$/);if(m){html+="<div class=\\"stargate-rule-status-row\\"><span>"+stargateRulesHtml(m[1])+"</span><strong>"+stargateRulesHtml(m[2])+"</strong></div>";}});return html||"<div class=\\"stargate-rule-status-row\\"><span>' .. ui_text("Result", "结果") .. '</span><strong>' .. ui_text("No result", "无结果") .. '</strong></div>";}',
    'function stargateRulesSetResult(text){var box=document.querySelector(".stargate-rule-test");if(!box)return;var old=box.querySelector(".stargate-rule-test-result");if(old)old.parentNode.removeChild(old);var node=document.createElement("div");node.className="stargate-rule-test-result";node.innerHTML=stargateRulesRows(text);box.appendChild(node);}',
    'function stargateRulesTestPolicy(){var input=document.getElementById("stargate-rules-target");var v=input?input.value.replace(/^\\s+|\\s+$/g,""):"";if(!v){alert("' .. ui_text("Domain or IP is required.", "请输入域名或 IP。") .. '");return;}XHR.get("' .. dispatcher.build_url("admin", "services", "stargate", "rules_test") .. '",{target:v},function(x,rv){if(rv&&rv.output){stargateRulesSetResult(rv.output);}else{stargateRulesSetResult("Result: "+(rv&&rv.ok?"OK":"Failed"));}});}',
    '//]]>',
    '</script>'
  }, "\n")
end
private_direct = s:option(Flag, "private_direct", translate("Private IP direct"))
private_direct.default = "1"
private_direct.rmempty = false

block_quic = s:option(Flag, "block_quic", translate("Block QUIC"))
block_quic.default = "1"
block_quic.rmempty = false
block_quic.description = ui_text("Reject LAN UDP/443 at the firewall so browsers and apps fall back from HTTP/3/QUIC to TCP/TLS. Re-apply forwarding after changing this option.", "在防火墙层拒绝局域网 UDP/443，让浏览器和应用从 HTTP/3/QUIC 回退到 TCP/TLS。修改后需要重新应用转发。")

return m
