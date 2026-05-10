local sys = require "luci.sys"
local http = require "luci.http"
local util = require "luci.util"
local dispatcher = require "luci.dispatcher"

m = Map("stargate", translate("Node"))
m.description = translate("Manage a small AnyTLS node list. Use a node to copy it into the active sing-box config.")

local function pc(value)
  return util.pcdata(value or "")
end

local function jsq(value)
  value = value or ""
  value = value:gsub("\\", "\\\\")
  value = value:gsub("'", "\\'")
  value = value:gsub("\r", "\\r")
  value = value:gsub("\n", "\\n")
  return pc(value)
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
elseif action == "edit" then
  local id = http.formvalue("edit_id") or ""
  local label = http.formvalue("edit_label") or ""
  local server = http.formvalue("edit_server") or ""
  local port = http.formvalue("edit_port") or ""
  local password = http.formvalue("edit_password") or ""
  local sni = http.formvalue("edit_sni") or ""
  local insecure = http.formvalue("edit_insecure") == "1" and "1" or "0"
  message = sys.exec("/usr/share/stargate/stargate.sh node-update " ..
    util.shellquote(id) .. " " ..
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

list = m:section(SimpleSection, translate("Node list"))
list.template = "cbi/nullsection"

nodes = list:option(DummyValue, "_nodes")
nodes.rawhtml = true
function nodes.cfgvalue()
  local rows = sys.exec("/usr/share/stargate/stargate.sh node-list 2>/dev/null")
  local html = {
    '<style>',
    '.stargate-node-list{max-width:1180px;margin:8px auto 16px}',
    '.stargate-node-tools{display:flex;justify-content:flex-end;gap:10px;margin:0 0 14px}',
    '.stargate-node-row{display:grid;grid-template-columns:34px minmax(180px,1.3fr) minmax(150px,1fr) 92px 280px;gap:12px;align-items:center;padding:12px 14px;border-top:1px solid rgba(127,127,127,.18)}',
    '.stargate-node-row:nth-child(even){background:rgba(127,127,127,.06)}',
    '.stargate-node-row-active{box-shadow:inset 3px 0 0 #8ab4f8}',
    '.stargate-node-name{font-weight:600}',
    '.stargate-node-meta{font-size:12px;opacity:.72;margin-top:3px}',
    '.stargate-node-actions-inline{display:flex;gap:8px;justify-content:flex-end;flex-wrap:wrap}',
    '.stargate-node-grid{display:grid;grid-template-columns:repeat(2,minmax(220px,1fr));gap:12px}',
    '.stargate-node-field label{display:block;font-size:12px;opacity:.72;margin-bottom:5px}',
    '.stargate-node-field input,.stargate-node-field textarea{width:100%;box-sizing:border-box}',
    '.stargate-node-field textarea{min-height:96px;resize:vertical}',
    '.stargate-node-modal{display:none;position:fixed;top:0;right:0;bottom:0;left:300px;z-index:9000;align-items:center;justify-content:center;background:rgba(0,0,0,.56);padding:18px;box-sizing:border-box}',
    '.stargate-node-modal.stargate-node-modal-open{display:flex}',
    '.stargate-node-dialog{width:min(720px,calc(100vw - 340px));max-height:calc(100vh - 42px);overflow:auto;border:1px solid rgba(140,140,140,.55);border-radius:8px;background:#1f1f1f;color:#d8d8d8;box-shadow:0 18px 48px rgba(0,0,0,.45)}',
    '.stargate-node-dialog-head{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:14px 16px;border-bottom:1px solid rgba(140,140,140,.28);background:#2b2b2b}',
    '.stargate-node-dialog-title{font-size:16px;font-weight:650}',
    '.stargate-node-dialog-body{padding:16px}',
    '.stargate-node-dialog-actions{display:flex;justify-content:flex-end;gap:10px;margin-top:16px}',
    '.stargate-node-x{min-width:34px}',
    '.stargate-node-dialog input,.stargate-node-dialog textarea{background:#202020;color:#d8d8d8;border-color:rgba(140,140,140,.45)}',
    '.stargate-node-dialog textarea{min-height:180px}',
    '@media screen and (max-width:1180px){.stargate-node-modal{left:0}.stargate-node-dialog{width:min(720px,calc(100vw - 36px))}}',
    '@media screen and (max-width:720px){.stargate-node-grid{grid-template-columns:1fr}.stargate-node-tools{justify-content:flex-start;flex-wrap:wrap}.stargate-node-modal{padding:12px}.stargate-node-dialog{width:calc(100vw - 24px);max-height:calc(100vh - 24px)}}',
    '@media screen and (max-width:940px){.stargate-node-row{grid-template-columns:34px 1fr}.stargate-node-actions-inline{grid-column:2;justify-content:flex-start}}',
    '</style>',
    '<div class="stargate-node-list">',
    '<input type="hidden" id="stargate_node_action" name="stargate_node_action" value="" />',
    '<input type="hidden" id="stargate_edit_id" name="edit_id" value="" />',
    '<div class="stargate-node-tools">',
    '<button class="cbi-button cbi-button-add" type="button" onclick="stargateOpenNodeModal(\'stargate-add-node\')">' .. ui_text("Add node", "添加节点") .. '</button>',
    '<button class="cbi-button cbi-button-add" type="button" onclick="stargateOpenNodeModal(\'stargate-add-link\')">' .. ui_text("Add by link", "通过链接添加") .. '</button>',
    '</div>'
  }
  local count = 0
  for line in rows:gmatch("[^\r\n]+") do
    local id, active, type_name, label, server, port, sni, insecure = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
    if id then
      count = count + 1
      local badge = active == "1" and ui_text("Active", "当前") or ""
      local checked = active == "1" and "checked" or ""
      local active_class = active == "1" and " stargate-node-row-active" or ""
      html[#html + 1] = '<div class="stargate-node-row' .. active_class .. '">'
      html[#html + 1] = '<div><input type="radio" name="stargate_active_node_view" disabled ' .. checked .. ' /></div>'
      html[#html + 1] = '<div><div class="stargate-node-name">' .. pc(label) .. '</div><div class="stargate-node-meta">' .. pc(type_name) .. ' ' .. pc(badge) .. '</div></div>'
      html[#html + 1] = '<div><div>' .. pc(server) .. ':' .. pc(port) .. '</div><div class="stargate-node-meta">SNI ' .. pc(sni ~= "" and sni or "-") .. '</div></div>'
      html[#html + 1] = '<div>' .. (insecure == "1" and ui_text("Insecure", "不验证") or ui_text("TLS verify", "验证 TLS")) .. '</div>'
      html[#html + 1] = '<div class="stargate-node-actions-inline">'
      html[#html + 1] = '<a class="cbi-button cbi-button-apply" href="' .. base_url .. '?stargate_node_action=use&node_id=' .. pc(id) .. '">' .. ui_text("Use this node", "使用此节点") .. '</a>'
      html[#html + 1] = '<button class="cbi-button" type="button" onclick="stargateEditNode(\'' .. jsq(id) .. '\',\'' .. jsq(label) .. '\',\'' .. jsq(server) .. '\',\'' .. jsq(port) .. '\',\'' .. jsq(sni) .. '\',\'' .. jsq(insecure) .. '\')">' .. ui_text("Edit", "编辑") .. '</button>'
      html[#html + 1] = '<a class="cbi-button cbi-button-remove" href="' .. base_url .. '?stargate_node_action=delete&node_id=' .. pc(id) .. '">' .. ui_text("Delete", "删除") .. '</a>'
      html[#html + 1] = '</div></div>'
    end
  end
  if count == 0 then
    html[#html + 1] = '<div class="stargate-node-row"><div></div><div>' .. ui_text("No nodes yet", "还没有节点") .. '</div></div>'
  end
  html[#html + 1] = '<div id="stargate-add-node" class="stargate-node-modal" onclick="if(event.target===this)stargateCloseNodeModal(this)">'
  html[#html + 1] = '<div class="stargate-node-dialog">'
  html[#html + 1] = '<div class="stargate-node-dialog-head"><div class="stargate-node-dialog-title">' .. ui_text("Add node", "添加节点") .. '</div><button class="cbi-button stargate-node-x" type="button" onclick="stargateCloseNodeModal(this)">&times;</button></div>'
  html[#html + 1] = '<div class="stargate-node-dialog-body">'
  html[#html + 1] = '<div class="stargate-node-grid">'
  html[#html + 1] = '<div class="stargate-node-field"><label>' .. ui_text("Label", "标签") .. '</label><input name="add_label" placeholder="primary" /></div>'
  html[#html + 1] = '<div class="stargate-node-field"><label>' .. ui_text("Server", "服务器") .. '</label><input name="add_server" placeholder="example.com" /></div>'
  html[#html + 1] = '<div class="stargate-node-field"><label>' .. ui_text("Port", "端口") .. '</label><input name="add_port" value="443" /></div>'
  html[#html + 1] = '<div class="stargate-node-field"><label>' .. translate("SNI") .. '</label><input name="add_sni" placeholder="example.com" /></div>'
  html[#html + 1] = '<div class="stargate-node-field"><label>' .. ui_text("Password", "密码") .. '</label><input name="add_password" type="password" /></div>'
  html[#html + 1] = '<div class="stargate-node-field"><label>' .. ui_text("Allow insecure TLS", "允许不安全 TLS") .. '</label><input type="checkbox" name="add_insecure" value="1" checked /></div>'
  html[#html + 1] = '</div>'
  html[#html + 1] = '<div class="stargate-node-dialog-actions"><button class="cbi-button" type="button" onclick="stargateCloseNodeModal(this)">' .. ui_text("Cancel", "取消") .. '</button><button class="cbi-button cbi-button-apply" type="submit" onclick="document.getElementById(\'stargate_node_action\').value=\'add\'">' .. ui_text("Add", "添加") .. '</button></div>'
  html[#html + 1] = '</div></div></div>'
  html[#html + 1] = '<div id="stargate-add-link" class="stargate-node-modal" onclick="if(event.target===this)stargateCloseNodeModal(this)">'
  html[#html + 1] = '<div class="stargate-node-dialog">'
  html[#html + 1] = '<div class="stargate-node-dialog-head"><div class="stargate-node-dialog-title">' .. ui_text("Add node by link", "通过链接添加节点") .. '</div><button class="cbi-button stargate-node-x" type="button" onclick="stargateCloseNodeModal(this)">&times;</button></div>'
  html[#html + 1] = '<div class="stargate-node-dialog-body">'
  html[#html + 1] = '<div class="stargate-node-field"><label>' .. ui_text("AnyTLS link", "AnyTLS 链接") .. '</label><textarea name="link_uri" placeholder="anytls://password@example.com:443/?insecure=1&sni=example.com#name"></textarea></div>'
  html[#html + 1] = '<div class="stargate-node-dialog-actions"><button class="cbi-button" type="button" onclick="stargateCloseNodeModal(this)">' .. ui_text("Cancel", "取消") .. '</button><button class="cbi-button cbi-button-apply" type="submit" onclick="document.getElementById(\'stargate_node_action\').value=\'add-link\'">' .. ui_text("Add by link", "通过链接添加") .. '</button></div>'
  html[#html + 1] = '</div></div></div>'
  html[#html + 1] = '<div id="stargate-edit-node" class="stargate-node-modal" onclick="if(event.target===this)stargateCloseNodeModal(this)">'
  html[#html + 1] = '<div class="stargate-node-dialog">'
  html[#html + 1] = '<div class="stargate-node-dialog-head"><div class="stargate-node-dialog-title">' .. ui_text("Edit node", "编辑节点") .. '</div><button class="cbi-button stargate-node-x" type="button" onclick="stargateCloseNodeModal(this)">&times;</button></div>'
  html[#html + 1] = '<div class="stargate-node-dialog-body">'
  html[#html + 1] = '<div class="stargate-node-grid">'
  html[#html + 1] = '<div class="stargate-node-field"><label>' .. ui_text("Label", "标签") .. '</label><input id="stargate_edit_label" name="edit_label" placeholder="primary" /></div>'
  html[#html + 1] = '<div class="stargate-node-field"><label>' .. ui_text("Server", "服务器") .. '</label><input id="stargate_edit_server" name="edit_server" placeholder="example.com" /></div>'
  html[#html + 1] = '<div class="stargate-node-field"><label>' .. ui_text("Port", "端口") .. '</label><input id="stargate_edit_port" name="edit_port" /></div>'
  html[#html + 1] = '<div class="stargate-node-field"><label>' .. translate("SNI") .. '</label><input id="stargate_edit_sni" name="edit_sni" placeholder="example.com" /></div>'
  html[#html + 1] = '<div class="stargate-node-field"><label>' .. ui_text("Password", "密码") .. '</label><input id="stargate_edit_password" name="edit_password" type="password" placeholder="' .. ui_text("Keep unchanged if empty", "留空则不修改") .. '" /></div>'
  html[#html + 1] = '<div class="stargate-node-field"><label>' .. ui_text("Allow insecure TLS", "允许不安全 TLS") .. '</label><input id="stargate_edit_insecure" type="checkbox" name="edit_insecure" value="1" /></div>'
  html[#html + 1] = '</div>'
  html[#html + 1] = '<div class="stargate-node-dialog-actions"><button class="cbi-button" type="button" onclick="stargateCloseNodeModal(this)">' .. ui_text("Cancel", "取消") .. '</button><button class="cbi-button cbi-button-apply" type="submit" onclick="document.getElementById(\'stargate_node_action\').value=\'edit\'">' .. ui_text("Save", "保存") .. '</button></div>'
  html[#html + 1] = '</div></div></div>'
  html[#html + 1] = '<script type="text/javascript">'
  html[#html + 1] = '//<![CDATA['
  html[#html + 1] = 'function stargateOpenNodeModal(id){var n=document.getElementById(id);if(!n)return;n.className=n.className.replace(/\\s*stargate-node-modal-open/g,"")+" stargate-node-modal-open";var f=n.querySelector("input,textarea,button");if(f&&f.focus)setTimeout(function(){f.focus();},40);}'
  html[#html + 1] = 'function stargateCloseNodeModal(el){var n=el;while(n&&(!n.className||String(n.className).indexOf("stargate-node-modal")<0)){n=n.parentNode;}if(n)n.className=n.className.replace(/\\s*stargate-node-modal-open/g,"");}'
  html[#html + 1] = 'function stargateSetValue(id,value){var n=document.getElementById(id);if(n)n.value=value||"";}'
  html[#html + 1] = 'function stargateEditNode(id,label,server,port,sni,insecure){stargateSetValue("stargate_edit_id",id);stargateSetValue("stargate_edit_label",label);stargateSetValue("stargate_edit_server",server);stargateSetValue("stargate_edit_port",port);stargateSetValue("stargate_edit_sni",sni);stargateSetValue("stargate_edit_password","");var c=document.getElementById("stargate_edit_insecure");if(c)c.checked=(String(insecure)==="1");stargateOpenNodeModal("stargate-edit-node");}'
  html[#html + 1] = 'document.onkeydown=function(e){e=e||window.event;if((e.key==="Escape"||e.keyCode===27)){var ns=document.querySelectorAll(".stargate-node-modal-open");for(var i=0;i<ns.length;i++)stargateCloseNodeModal(ns[i]);}};'
  html[#html + 1] = '//]]>'
  html[#html + 1] = '</script>'
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
