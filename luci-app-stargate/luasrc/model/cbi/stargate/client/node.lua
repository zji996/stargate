local sys = require "luci.sys"
local http = require "luci.http"
local util = require "luci.util"
local dispatcher = require "luci.dispatcher"

m = Map("stargate", translate("Node"))
m.description = translate("Manage a small AnyTLS node list. Use a node to copy it into the active sing-box config.")

local function pc(value)
  return util.pcdata(value or "")
end

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

local function uci_get(section, option, default)
  local value = trim(sys.exec("uci -q get stargate." .. section .. "." .. option .. " 2>/dev/null"))
  if value == "" then
    return default or ""
  end
  return value
end

local action = http.formvalue("stargate_node_action")
local message = nil
if action == "use" or action == "delete" then
  local id = http.formvalue("node_id") or ""
  if id:match("^[A-Za-z0-9_%-]+$") then
    message = sys.exec("/usr/share/stargate/stargate.sh node-" .. action .. " " .. id .. " 2>&1")
  else
    message = "invalid node id"
  end
elseif action == "add" then
  local label = http.formvalue("add_label") or ""
  local server = http.formvalue("add_server") or ""
  local port = http.formvalue("add_port") or ""
  local password = http.formvalue("add_password") or ""
  local sni = http.formvalue("add_sni") or ""
  local insecure = http.formvalue("add_insecure") == "1" and "1" or "0"
  message = sys.exec("/usr/share/stargate/stargate.sh node-add " ..
    util.shellquote(label) .. " " ..
    util.shellquote(server) .. " " ..
    util.shellquote(port) .. " " ..
    util.shellquote(password) .. " " ..
    util.shellquote(sni) .. " " ..
    util.shellquote(insecure) .. " 2>&1")
elseif action == "add-link" then
  local link = http.formvalue("link_uri") or ""
  message = sys.exec("/usr/share/stargate/stargate.sh node-add-link " .. util.shellquote(link) .. " 2>&1")
elseif action == "save-active" then
  local label = http.formvalue("active_label") or ""
  local server = http.formvalue("active_server") or ""
  local port = http.formvalue("active_port") or ""
  local password = http.formvalue("active_password") or ""
  local sni = http.formvalue("active_sni") or ""
  local insecure = http.formvalue("active_insecure") == "1" and "1" or "0"
  message = sys.exec("/usr/share/stargate/stargate.sh node-save-active " ..
    util.shellquote(label) .. " " ..
    util.shellquote(server) .. " " ..
    util.shellquote(port) .. " " ..
    util.shellquote(password) .. " " ..
    util.shellquote(sni) .. " " ..
    util.shellquote(insecure) .. " 2>&1")
end

if message then
  m.message = "<pre>" .. pc(message) .. "</pre>"
end

local base_url = dispatcher.build_url("admin", "services", "stargate", "node")

toolbar = m:section(SimpleSection, translate("Node actions"))
toolbar.template = "cbi/nullsection"

node_toolbar = toolbar:option(DummyValue, "_node_toolbar")
node_toolbar.rawhtml = true
function node_toolbar.cfgvalue()
  local active_label = uci_get("node", "label", "primary")
  local active_type = uci_get("node", "type", "anytls")
  local active_server = uci_get("node", "server", "")
  local active_port = uci_get("node", "server_port", "443")
  local active_password = uci_get("node", "password", "")
  local active_sni = uci_get("node", "sni", "")
  local active_insecure = uci_get("node", "insecure", "1")
  local active_target = active_server ~= "" and (active_server .. ":" .. active_port) or ui_text("Unset", "未设置")
  return table.concat({
    '<style>',
    '.stargate-node-panel{max-width:1160px;margin:8px auto 18px}',
    '.stargate-node-card{display:flex;align-items:center;justify-content:space-between;gap:18px;padding:16px 18px;border:1px solid rgba(127,127,127,.28);border-radius:8px;background:rgba(127,127,127,.05)}',
    '.stargate-node-title{font-size:13px;opacity:.72;margin-bottom:4px}',
    '.stargate-node-current{font-size:22px;font-weight:650;line-height:1.25}',
    '.stargate-node-meta{font-size:12px;opacity:.72;margin-top:4px}',
    '.stargate-node-buttons{display:flex;flex-wrap:wrap;gap:10px;justify-content:flex-end}',
    '.stargate-node-grid{display:grid;grid-template-columns:repeat(2,minmax(220px,1fr));gap:12px}',
    '.stargate-node-field label{display:block;font-size:12px;opacity:.72;margin-bottom:5px}',
    '.stargate-node-field input,.stargate-node-field textarea{width:100%;box-sizing:border-box}',
    '.stargate-node-field textarea{min-height:96px;resize:vertical}',
    '.stargate-node-modal{display:none;position:fixed;inset:0;z-index:2000;align-items:center;justify-content:center;background:rgba(0,0,0,.56);padding:18px}',
    '.stargate-node-modal.stargate-node-modal-open{display:flex}',
    '.stargate-node-dialog{width:min(720px,calc(100vw - 36px));max-height:calc(100vh - 42px);overflow:auto;border:1px solid rgba(127,127,127,.36);border-radius:8px;background:var(--background-color-high,#fff);box-shadow:0 18px 48px rgba(0,0,0,.35)}',
    '.stargate-node-dialog-head{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:14px 16px;border-bottom:1px solid rgba(127,127,127,.22)}',
    '.stargate-node-dialog-title{font-size:16px;font-weight:650}',
    '.stargate-node-dialog-body{padding:16px}',
    '.stargate-node-dialog-actions{display:flex;justify-content:flex-end;gap:10px;margin-top:16px}',
    '.stargate-node-x{min-width:34px}',
    '@media screen and (max-width:720px){.stargate-node-grid{grid-template-columns:1fr}}',
    '@media screen and (max-width:820px){.stargate-node-card{align-items:flex-start;flex-direction:column}.stargate-node-buttons{justify-content:flex-start}}',
    '</style>',
    '<div class="stargate-node-panel">',
    '<input type="hidden" id="stargate_node_action" name="stargate_node_action" value="" />',
    '<div class="stargate-node-card">',
    '<div>',
    '<div class="stargate-node-title">' .. ui_text("Active node", "当前使用节点") .. '</div>',
    '<div class="stargate-node-current">' .. pc(active_label) .. '</div>',
    '<div class="stargate-node-meta">' .. pc(active_type) .. ' &middot; ' .. pc(active_target) .. ' &middot; SNI ' .. pc(active_sni ~= "" and active_sni or "-") .. '</div>',
    '</div>',
    '<div class="stargate-node-buttons">',
    '<button class="cbi-button cbi-button-apply" type="button" onclick="stargateOpenNodeModal(\'stargate-edit-active\')">' .. ui_text("Edit node", "编辑节点") .. '</button>',
    '<button class="cbi-button cbi-button-add" type="button" onclick="stargateOpenNodeModal(\'stargate-add-node\')">' .. ui_text("Add node", "添加节点") .. '</button>',
    '<button class="cbi-button cbi-button-add" type="button" onclick="stargateOpenNodeModal(\'stargate-add-link\')">' .. ui_text("Add by link", "通过链接添加") .. '</button>',
    '</div>',
    '</div>',
    '</div>',
    '<div id="stargate-edit-active" class="stargate-node-modal" onclick="if(event.target===this)stargateCloseNodeModal(this)">',
    '<div class="stargate-node-dialog">',
    '<div class="stargate-node-dialog-head"><div class="stargate-node-dialog-title">' .. ui_text("Edit node", "编辑节点") .. '</div><button class="cbi-button stargate-node-x" type="button" onclick="stargateCloseNodeModal(this)">&times;</button></div>',
    '<div class="stargate-node-dialog-body">',
    '<div class="stargate-node-grid">',
    '<div class="stargate-node-field"><label>' .. ui_text("Label", "标签") .. '</label><input name="active_label" value="' .. pc(active_label) .. '" placeholder="primary" /></div>',
    '<div class="stargate-node-field"><label>' .. ui_text("Server", "服务器") .. '</label><input name="active_server" value="' .. pc(active_server) .. '" placeholder="example.com" /></div>',
    '<div class="stargate-node-field"><label>' .. ui_text("Port", "端口") .. '</label><input name="active_port" value="' .. pc(active_port) .. '" /></div>',
    '<div class="stargate-node-field"><label>' .. translate("SNI") .. '</label><input name="active_sni" value="' .. pc(active_sni) .. '" placeholder="example.com" /></div>',
    '<div class="stargate-node-field"><label>' .. ui_text("Password", "密码") .. '</label><input name="active_password" value="' .. pc(active_password) .. '" type="password" /></div>',
    '<div class="stargate-node-field"><label>' .. ui_text("Allow insecure TLS", "允许不安全 TLS") .. '</label><input type="checkbox" name="active_insecure" value="1" ' .. (active_insecure == "1" and "checked" or "") .. ' /></div>',
    '</div>',
    '<div class="stargate-node-dialog-actions"><button class="cbi-button" type="button" onclick="stargateCloseNodeModal(this)">' .. ui_text("Cancel", "取消") .. '</button><button class="cbi-button cbi-button-apply" type="submit" onclick="document.getElementById(\'stargate_node_action\').value=\'save-active\'">' .. ui_text("Save", "保存") .. '</button></div>',
    '</div>',
    '</div>',
    '</div>',
    '<div id="stargate-add-node" class="stargate-node-modal" onclick="if(event.target===this)stargateCloseNodeModal(this)">',
    '<div class="stargate-node-dialog">',
    '<div class="stargate-node-dialog-head"><div class="stargate-node-dialog-title">' .. ui_text("Add node", "添加节点") .. '</div><button class="cbi-button stargate-node-x" type="button" onclick="stargateCloseNodeModal(this)">&times;</button></div>',
    '<div class="stargate-node-dialog-body">',
    '<div class="stargate-node-grid">',
    '<div class="stargate-node-field"><label>' .. ui_text("Label", "标签") .. '</label><input name="add_label" placeholder="primary" /></div>',
    '<div class="stargate-node-field"><label>' .. ui_text("Server", "服务器") .. '</label><input name="add_server" placeholder="example.com" /></div>',
    '<div class="stargate-node-field"><label>' .. ui_text("Port", "端口") .. '</label><input name="add_port" value="443" /></div>',
    '<div class="stargate-node-field"><label>' .. translate("SNI") .. '</label><input name="add_sni" placeholder="example.com" /></div>',
    '<div class="stargate-node-field"><label>' .. ui_text("Password", "密码") .. '</label><input name="add_password" type="password" /></div>',
    '<div class="stargate-node-field"><label>' .. ui_text("Allow insecure TLS", "允许不安全 TLS") .. '</label><input type="checkbox" name="add_insecure" value="1" checked /></div>',
    '</div>',
    '<div class="stargate-node-dialog-actions"><button class="cbi-button" type="button" onclick="stargateCloseNodeModal(this)">' .. ui_text("Cancel", "取消") .. '</button><button class="cbi-button cbi-button-apply" type="submit" onclick="document.getElementById(\'stargate_node_action\').value=\'add\'">' .. ui_text("Add", "添加") .. '</button></div>',
    '</div>',
    '</div>',
    '</div>',
    '<div id="stargate-add-link" class="stargate-node-modal" onclick="if(event.target===this)stargateCloseNodeModal(this)">',
    '<div class="stargate-node-dialog">',
    '<div class="stargate-node-dialog-head"><div class="stargate-node-dialog-title">' .. ui_text("Add node by link", "通过链接添加节点") .. '</div><button class="cbi-button stargate-node-x" type="button" onclick="stargateCloseNodeModal(this)">&times;</button></div>',
    '<div class="stargate-node-dialog-body">',
    '<div class="stargate-node-field"><label>' .. ui_text("AnyTLS link", "AnyTLS 链接") .. '</label><textarea name="link_uri" placeholder="anytls://password@example.com:443/?insecure=1&sni=example.com#name"></textarea></div>',
    '<div class="stargate-node-dialog-actions"><button class="cbi-button" type="button" onclick="stargateCloseNodeModal(this)">' .. ui_text("Cancel", "取消") .. '</button><button class="cbi-button cbi-button-apply" type="submit" onclick="document.getElementById(\'stargate_node_action\').value=\'add-link\'">' .. ui_text("Add by link", "通过链接添加") .. '</button></div>',
    '</div>',
    '</div>',
    '</div>',
    '<script type="text/javascript">',
    '//<![CDATA[',
    'function stargateOpenNodeModal(id){var n=document.getElementById(id);if(!n)return;n.className=n.className.replace(/\\s*stargate-node-modal-open/g,"")+" stargate-node-modal-open";var f=n.querySelector("input,textarea,button");if(f&&f.focus)setTimeout(function(){f.focus();},40);}',
    'function stargateCloseNodeModal(el){var n=el;while(n&&(!n.className||String(n.className).indexOf("stargate-node-modal")<0)){n=n.parentNode;}if(n)n.className=n.className.replace(/\\s*stargate-node-modal-open/g,"");}',
    'document.onkeydown=function(e){e=e||window.event;if((e.key==="Escape"||e.keyCode===27)){var ns=document.querySelectorAll(".stargate-node-modal-open");for(var i=0;i<ns.length;i++)stargateCloseNodeModal(ns[i]);}};',
    '//]]>',
    '</script>'
  }, "\n")
end

list = m:section(SimpleSection, translate("Node list"))
list.template = "cbi/nullsection"

nodes = list:option(DummyValue, "_nodes")
nodes.rawhtml = true
function nodes.cfgvalue()
  local rows = sys.exec("/usr/share/stargate/stargate.sh node-list 2>/dev/null")
  local html = {
    '<style>',
    '.stargate-node-list{max-width:1180px;margin:8px auto 16px}',
    '.stargate-node-row{display:grid;grid-template-columns:28px minmax(180px,1.4fr) minmax(120px,1fr) 88px 170px;gap:12px;align-items:center;padding:12px 14px;border-top:1px solid rgba(127,127,127,.18)}',
    '.stargate-node-row:nth-child(even){background:rgba(127,127,127,.06)}',
    '.stargate-node-name{font-weight:600}',
    '.stargate-node-meta{font-size:12px;opacity:.72;margin-top:3px}',
    '.stargate-node-actions-inline{display:flex;gap:8px;justify-content:flex-end}',
    '@media screen and (max-width:820px){.stargate-node-row{grid-template-columns:1fr}.stargate-node-actions-inline{justify-content:flex-start}}',
    '</style>',
    '<div class="stargate-node-list">'
  }
  local count = 0
  for line in rows:gmatch("[^\r\n]+") do
    local id, active, type_name, label, server, port, sni, insecure = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
    if id then
      count = count + 1
      local badge = active == "1" and ui_text("Active", "当前") or ""
      html[#html + 1] = '<div class="stargate-node-row">'
      html[#html + 1] = '<div><input type="checkbox" disabled ' .. (active == "1" and "checked" or "") .. ' /></div>'
      html[#html + 1] = '<div><div class="stargate-node-name">' .. pc(label) .. '</div><div class="stargate-node-meta">' .. pc(type_name) .. ' ' .. pc(badge) .. '</div></div>'
      html[#html + 1] = '<div><div>' .. pc(server) .. ':' .. pc(port) .. '</div><div class="stargate-node-meta">SNI ' .. pc(sni ~= "" and sni or "-") .. '</div></div>'
      html[#html + 1] = '<div>' .. (insecure == "1" and ui_text("Insecure", "不验证") or ui_text("TLS verify", "验证 TLS")) .. '</div>'
      html[#html + 1] = '<div class="stargate-node-actions-inline">'
      html[#html + 1] = '<a class="cbi-button cbi-button-apply" href="' .. base_url .. '?stargate_node_action=use&node_id=' .. pc(id) .. '">' .. ui_text("Use", "使用") .. '</a>'
      html[#html + 1] = '<a class="cbi-button cbi-button-remove" href="' .. base_url .. '?stargate_node_action=delete&node_id=' .. pc(id) .. '">' .. ui_text("Delete", "删除") .. '</a>'
      html[#html + 1] = '</div></div>'
    end
  end
  if count == 0 then
    html[#html + 1] = '<div class="stargate-node-row"><div>' .. ui_text("No nodes yet", "还没有节点") .. '</div></div>'
  end
  html[#html + 1] = '</div>'
  return table.concat(html, "\n")
end

i = m:section(NamedSection, "inbound", "inbound", translate("Local inbound"))
i.anonymous = true

socks_listen = i:option(Value, "socks_listen", translate("SOCKS listen"))
socks_listen.default = "127.0.0.1"

socks_port = i:option(Value, "socks_port", translate("SOCKS port"))
socks_port.datatype = "port"
socks_port.default = "10808"

http_listen = i:option(Value, "http_listen", translate("HTTP listen"))
http_listen.default = "127.0.0.1"

http_port = i:option(Value, "http_port", translate("HTTP port"))
http_port.datatype = "port"
http_port.default = "10809"

return m
