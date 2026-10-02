local sys = require "luci.sys"
local http = require "luci.http"
local util = require "luci.util"
local dispatcher = require "luci.dispatcher"
local common = require "luci.model.stargate.common"

m = Map("stargate", translate("Node"))
common.prepare_map(m)
m.description = translate("Manage a small AnyTLS node list. Use a node to copy it into the active sing-box config.")

local pc = common.pc
local trim = common.trim
local ui_text = common.ui_text

local function jsq(value)
  value = value or ""
  value = value:gsub("\\", "\\\\")
  value = value:gsub("'", "\\'")
  value = value:gsub("\r", "\\r")
  value = value:gsub("\n", "\\n")
  return pc(value)
end

local function js_literal(value)
  local quoted = string.format("%q", value or "")
  return (quoted:gsub("[<>&]", function(char)
    return string.format("\\x%02X", string.byte(char))
  end))
end

local function uci_get(section, option, default)
  local value = trim(sys.exec("uci -q get stargate." .. section .. "." .. option .. " 2>/dev/null"))
  if value == "" then
    return default or ""
  end
  return value
end

local function form_value(name, default)
  local value = http.formvalue(name)
  if type(value) == "table" then
    for index = #value, 1, -1 do
      if type(value[index]) == "string" and value[index] ~= "" then
        return value[index]
      end
    end
    value = value[#value]
  end
  if type(value) ~= "string" then
    return default or ""
  end
  return value
end

local action = common.action("stargate_node_action")
local message = nil
if action == "use" or action == "delete" then
  local id = form_value("node_id")
  if id:match("^[A-Za-z0-9_%-]+$") then
    message = sys.exec("/usr/share/stargate/stargate.sh node-" .. action .. " " .. id .. " 2>&1")
  else
    message = "invalid node id"
  end
elseif action == "port-set" then
  local id = form_value("port_node_id")
  local socks_port = form_value("port_socks")
  local http_port = form_value("port_http")
  local listen = form_value("port_listen", "0.0.0.0")
  local port_label = form_value("port_label")
  local old_id = form_value("port_orig_node_id")
  if id:match("^[A-Za-z0-9_%-]+$") then
    message = sys.exec("/usr/share/stargate/stargate.sh node-port-set " ..
      util.shellquote(id) .. " " ..
      util.shellquote(socks_port) .. " " ..
      util.shellquote(http_port) .. " " ..
      util.shellquote(listen) .. " " ..
      util.shellquote(port_label) .. " " ..
      util.shellquote(old_id) .. " 2>&1")
  else
    message = "invalid node id"
  end
elseif action == "port-remove" then
  local id = form_value("port_node_id")
  if id:match("^[A-Za-z0-9_%-]+$") then
    message = sys.exec("/usr/share/stargate/stargate.sh node-port-remove " .. util.shellquote(id) .. " 2>&1")
  else
    message = "invalid node id"
  end
elseif action == "add" then
  local label = form_value("add_label")
  local server = form_value("add_server")
  local port = form_value("add_port")
  local password = form_value("add_password")
  local sni = form_value("add_sni")
  local insecure = form_value("add_insecure") == "1" and "1" or "0"
  message = sys.exec("/usr/share/stargate/stargate.sh node-add " ..
    util.shellquote(label) .. " " ..
    util.shellquote(server) .. " " ..
    util.shellquote(port) .. " " ..
    util.shellquote(password) .. " " ..
    util.shellquote(sni) .. " " ..
    util.shellquote(insecure) .. " 2>&1")
elseif action == "add-link" then
  local link = form_value("link_uri")
  message = sys.exec("/usr/share/stargate/stargate.sh node-add-link " .. util.shellquote(link) .. " 2>&1")
elseif action == "edit" then
  local id = form_value("edit_id")
  local label = form_value("edit_label")
  local server = form_value("edit_server")
  local port = form_value("edit_port")
  local password = form_value("edit_password")
  local sni = form_value("edit_sni")
  local insecure = form_value("edit_insecure") == "1" and "1" or "0"
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

-- Section 1: Node list (Pure Outbound Pool)
list = m:section(SimpleSection, ui_text("Node list", "节点列表"))
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
    '.stargate-node-field input,.stargate-node-field select,.stargate-node-field textarea{width:100%;box-sizing:border-box}',
    '.stargate-node-field textarea{min-height:96px;resize:vertical}',
    '.stargate-node-modal{display:none;position:fixed;top:0;right:0;bottom:0;left:300px;z-index:9000;align-items:center;justify-content:center;background:transparent;padding:18px;box-sizing:border-box}',
    '.stargate-node-modal.stargate-node-modal-open{display:flex}',
    '.stargate-node-dialog{width:min(720px,calc(100vw - 340px));max-height:calc(100vh - 42px);overflow:auto;border:1px solid rgba(140,140,140,.55);border-radius:8px;background:#1f1f1f;color:#d8d8d8;box-shadow:0 18px 48px rgba(0,0,0,.45)}',
    '.stargate-node-dialog-head{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:14px 16px;border-bottom:1px solid rgba(140,140,140,.28);background:#2b2b2b}',
    '.stargate-node-dialog-title{font-size:16px;font-weight:650}',
    '.stargate-node-dialog-body{padding:16px}',
    '.stargate-node-dialog-actions{display:flex;justify-content:flex-end;gap:10px;margin-top:16px}',
    '.stargate-node-x{min-width:34px}',
    '.stargate-node-dialog input,.stargate-node-dialog select,.stargate-node-dialog textarea{background:#202020;color:#d8d8d8;border-color:rgba(140,140,140,.45)}',
    '.stargate-port-table{width:100%;border-collapse:collapse;margin:12px 0 8px;border:1px solid rgba(127,127,127,.2);border-radius:6px;overflow:hidden}',
    '.stargate-port-table th,.stargate-port-table td{padding:10px 14px;text-align:left;border-bottom:1px solid rgba(127,127,127,.12)}',
    '.stargate-port-table th{background:rgba(127,127,127,.08);font-size:12px;font-weight:600;opacity:.8}',
    '.stargate-port-badge{display:inline-block;padding:2px 8px;border-radius:4px;background:rgba(138,180,248,0.18);color:#8ab4f8;font-weight:500;font-size:12px}',
    '.stargate-port-actions{display:flex;gap:6px;justify-content:flex-end}',
    '#cbi-stargate-inbound-_dedicated{display:block!important;margin:0!important;padding:18px 22px!important;border-top:1px solid rgba(127,127,127,.12)!important;width:100%!important;box-sizing:border-box!important}',
    '#cbi-stargate-inbound-_dedicated>.cbi-value-title{display:none!important}',
    '#cbi-stargate-inbound-_dedicated>.cbi-value-field{display:block!important;margin:0!important;width:100%!important}',
    '@media screen and (max-width:1180px){.stargate-node-modal{left:0}.stargate-node-dialog{width:min(720px,calc(100vw - 36px))}}',
    '@media screen and (max-width:720px){.stargate-node-grid{grid-template-columns:1fr}.stargate-node-tools{justify-content:flex-start;flex-wrap:wrap}.stargate-node-modal{padding:12px}.stargate-node-dialog{width:calc(100vw - 24px);max-height:calc(100vh - 24px)}}',
    '@media screen and (max-width:940px){.stargate-node-row{grid-template-columns:34px 1fr}.stargate-node-actions-inline{grid-column:2;justify-content:flex-start}}',
    '</style>',
    '<div class="stargate-node-list">',
    '<input type="hidden" id="stargate_node_action" name="stargate_node_action" value="" />',
    '<input type="hidden" id="stargate_node_id" name="node_id" value="" />',
    '<input type="hidden" id="stargate_edit_id" name="edit_id" value="" />',
    '<input type="hidden" id="stargate_port_node_id" name="port_node_id" value="" />',
    '<input type="hidden" id="stargate_port_orig_node_id" name="port_orig_node_id" value="" />',
    '<div class="stargate-node-tools">',
    '<button class="cbi-button cbi-button-add" type="button" onclick="stargateOpenNodeModal(\'stargate-add-node\')">' .. ui_text("Add node", "添加节点") .. '</button>',
    '<button class="cbi-button cbi-button-add" type="button" onclick="stargateOpenNodeModal(\'stargate-add-link\')">' .. ui_text("Add by link", "通过链接添加") .. '</button>',
    '</div>'
  }
  local count = 0

  for line in rows:gmatch("[^\r\n]+") do
    local id, active, type_name, label, server, port, sni, insecure, enable_port, socks_port, http_port, listen, port_label = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t?([^\t]*)$")
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
      html[#html + 1] = '<button type="button" class="cbi-button cbi-button-apply" data-field="stargate_node_action" data-stargate-action="use" data-node="' .. pc(id) .. '">' .. ui_text("Use this node", "使用此节点") .. '</button>'
      html[#html + 1] = '<button class="cbi-button" type="button" onclick="stargateEditNode(\'' .. jsq(id) .. '\',\'' .. jsq(label) .. '\',\'' .. jsq(server) .. '\',\'' .. jsq(port) .. '\',\'' .. jsq(sni) .. '\',\'' .. jsq(insecure) .. '\')">' .. ui_text("Edit", "编辑") .. '</button>'
      html[#html + 1] = '<button type="button" class="cbi-button cbi-button-remove" data-field="stargate_node_action" data-stargate-action="delete" data-confirm="' .. ui_text("Delete this node?", "删除此节点？") .. '" data-node="' .. pc(id) .. '">' .. ui_text("Delete", "删除") .. '</button>'
      html[#html + 1] = '</div></div>'
    end
  end
  if count == 0 then
    html[#html + 1] = '<div class="stargate-node-row"><div></div><div>' .. ui_text("No nodes yet", "还没有节点") .. '</div></div>'
  end

  -- Modal: Add Node
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

  -- Modal: Add Link
  html[#html + 1] = '<div id="stargate-add-link" class="stargate-node-modal" onclick="if(event.target===this)stargateCloseNodeModal(this)">'
  html[#html + 1] = '<div class="stargate-node-dialog">'
  html[#html + 1] = '<div class="stargate-node-dialog-head"><div class="stargate-node-dialog-title">' .. ui_text("Add node by link", "通过链接添加节点") .. '</div><button class="cbi-button stargate-node-x" type="button" onclick="stargateCloseNodeModal(this)">&times;</button></div>'
  html[#html + 1] = '<div class="stargate-node-dialog-body">'
  html[#html + 1] = '<div class="stargate-node-field"><label>' .. ui_text("AnyTLS link", "AnyTLS 链接") .. '</label><textarea name="link_uri" placeholder="anytls://password@example.com:443/?insecure=1&sni=example.com#name"></textarea></div>'
  html[#html + 1] = '<div class="stargate-node-dialog-actions"><button class="cbi-button" type="button" onclick="stargateCloseNodeModal(this)">' .. ui_text("Cancel", "取消") .. '</button><button class="cbi-button cbi-button-apply" type="submit" onclick="document.getElementById(\'stargate_node_action\').value=\'add-link\'">' .. ui_text("Add by link", "通过链接添加") .. '</button></div>'
  html[#html + 1] = '</div></div></div>'

  -- Modal: Edit Node
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

-- Section 2: Inbound Ports (分流与入站端口)
inbound = m:section(NamedSection, "inbound", "inbound", ui_text("Inbound Ports", "分流与入站端口"))
inbound.description = ui_text("Global default inbound and dedicated proxy inbounds. Dedicated ports can be bound to specific egress nodes for device-specific routing.", "全局主入站与独立分流代理端口。独立分流端口可绑定至特定出口节点，实现局域网设备按端口分流。")
inbound.anonymous = true

-- Part 1: Main Inbound (全局默认)
main_bound = inbound:option(DummyValue, "_main_bound", ui_text("Main inbound node", "主入站绑定出口"))
main_bound.rawhtml = true
function main_bound.cfgvalue()
  local active_server = uci_get("node", "server", "")
  local active_port = uci_get("node", "server_port", "443")
  local active_label = uci_get("node", "label", "")
  if active_label == "" then active_label = active_server end
  if active_server == "" then
    return '<span style="color:#f87171">' .. ui_text("None (please add and select an active node above)", "未设置（请在上方添加并选择主节点）") .. '</span>'
  end
  return '<strong>' .. pc(active_label) .. '</strong> <span style="font-size:12px;opacity:.75">(' .. pc(active_server) .. ':' .. pc(active_port) .. ' · ' .. ui_text("Fixed binding: carries transparent proxy and default local proxy", "固定绑定：承载透明代理与本机默认代理") .. ')</span>'
end

socks_listen = inbound:option(Value, "socks_listen", ui_text("SOCKS listen", "SOCKS 监听地址"))
socks_listen.default = "127.0.0.1"

socks_port = inbound:option(Value, "socks_port", ui_text("SOCKS port", "SOCKS 端口"))
socks_port.datatype = "port"
socks_port.default = "10808"

http_listen = inbound:option(Value, "http_listen", ui_text("HTTP listen", "HTTP 监听地址"))
http_listen.default = "127.0.0.1"

http_port = inbound:option(Value, "http_port", ui_text("HTTP port", "HTTP 端口"))
http_port.datatype = "port"
http_port.default = "10809"

-- Part 2: Dedicated Inbound Ports (独立分流端口)
dedicated = inbound:option(DummyValue, "_dedicated", "")
dedicated.rawhtml = true
function dedicated.cfgvalue()
  local rows = sys.exec("/usr/share/stargate/stargate.sh node-list 2>/dev/null")
  local next_ports = trim(sys.exec("/usr/share/stargate/stargate.sh node-next-ports 2>/dev/null"))
  local def_socks, def_http = next_ports:match("^([0-9]+)%s+([0-9]+)$")
  def_socks = def_socks or "10818"
  def_http = def_http or "10819"

  local all_nodes = {}
  local dedicated_ports = {}
  for line in rows:gmatch("[^\r\n]+") do
    local id, active, type_name, label, server, port, sni, insecure, enable_port, socks_port, http_port, listen, port_label = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t?([^\t]*)$")
    if id then
      local node_item = {
        id = id,
        label = label,
        server = server,
        port = port,
        sni = sni,
        insecure = insecure,
        enable_port = enable_port,
        socks_port = socks_port,
        http_port = http_port,
        listen = listen,
        port_label = port_label or ""
      }
      all_nodes[#all_nodes + 1] = node_item
      if enable_port == "1" then
        dedicated_ports[#dedicated_ports + 1] = node_item
      end
    end
  end

  local html = {
    '<div>',
    '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">',
    '<h3 style="margin:0;font-size:15px;font-weight:600">' .. ui_text("Dedicated Inbound Ports", "独立分流端口列表") .. '</h3>',
    '<button class="cbi-button cbi-button-add" type="button" onclick="stargateOpenAddPortModal(\'' .. def_socks .. '\',\'' .. def_http .. '\')">' .. ui_text("+ Add dedicated port", "+ 添加独立端口") .. '</button>',
    '</div>',
    '<div style="font-size:12px;opacity:.72;margin-bottom:12px">' .. ui_text("Assign dedicated LAN SOCKS/HTTP ports to specific nodes for device-specific routing without exposing unused nodes.", "为指定节点分配专属的 SOCKS/HTTP 端口，供局域网指定设备直接连接，无需将所有节点端口全部暴露。") .. '</div>',
    '<table class="stargate-port-table">',
    '<thead><tr><th>' .. ui_text("Purpose / Protocol", "端口用途 / 协议") .. '</th><th>' .. ui_text("Listen", "监听地址") .. '</th><th>' .. ui_text("SOCKS Port", "SOCKS 端口") .. '</th><th>' .. ui_text("HTTP Port", "HTTP 端口") .. '</th><th>' .. ui_text("Bound Node", "绑定出口节点") .. '</th><th style="text-align:right">' .. ui_text("Actions", "操作") .. '</th></tr></thead>',
    '<tbody>'
  }

  if #dedicated_ports == 0 then
    html[#html + 1] = '<tr><td colspan="6" style="text-align:center;opacity:.6;padding:16px">' .. ui_text("No dedicated ports configured yet.", "尚未配置独立分流端口。需要给局域网设备单独分流时可点击上方添加。") .. '</td></tr>'
  else
    for _, dp in ipairs(dedicated_ports) do
      local purpose = dp.port_label ~= "" and dp.port_label or dp.label
      html[#html + 1] = '<tr>'
      html[#html + 1] = '<td><strong>' .. pc(purpose) .. '</strong> <span style="font-size:11px;opacity:.7">/ AnyTLS</span></td>'
      html[#html + 1] = '<td><code>' .. pc(dp.listen ~= "" and dp.listen or "0.0.0.0") .. '</code></td>'
      html[#html + 1] = '<td>' .. (dp.socks_port ~= "" and ('<span class="stargate-port-badge">' .. pc(dp.socks_port) .. '</span>') or "-") .. '</td>'
      html[#html + 1] = '<td>' .. (dp.http_port ~= "" and ('<span class="stargate-port-badge">' .. pc(dp.http_port) .. '</span>') or "-") .. '</td>'
      html[#html + 1] = '<td><strong>' .. pc(dp.label) .. '</strong> <span style="font-size:11px;opacity:.7">(' .. pc(dp.server) .. ':' .. pc(dp.port) .. ')</span></td>'
      html[#html + 1] = '<td class="stargate-port-actions">'
      html[#html + 1] = '<button type="button" class="cbi-button" onclick="stargateEditPortModal(\'' .. jsq(dp.id) .. '\',\'' .. jsq(dp.socks_port) .. '\',\'' .. jsq(dp.http_port) .. '\',\'' .. jsq(dp.listen) .. '\',\'' .. jsq(dp.port_label) .. '\')">' .. ui_text("Edit", "编辑") .. '</button>'
      html[#html + 1] = '<button type="button" class="cbi-button cbi-button-remove" data-field="stargate_node_action" data-stargate-action="port-remove" data-confirm="' .. ui_text("Remove dedicated port for this node?", "移除此节点的独立端口？") .. '" data-port-node="' .. pc(dp.id) .. '">' .. ui_text("Delete", "删除") .. '</button>'
      html[#html + 1] = '</td>'
      html[#html + 1] = '</tr>'
    end
  end
  html[#html + 1] = '</tbody></table>'

  -- Modal: Dedicated Port
  local node_options = {}
  for _, item in ipairs(all_nodes) do
    local is_assigned = (item.enable_port == "1")
    local suffix = is_assigned and (" (" .. ui_text("Configured", "已配置端口") .. ")") or ""
    node_options[#node_options + 1] = '<option value="' .. pc(item.id) .. '" data-assigned="' .. (is_assigned and "1" or "0") .. '">' .. pc(item.label) .. ' (' .. pc(item.server) .. ')' .. suffix .. '</option>'
  end
  local node_options_html = table.concat(node_options, "")

  html[#html + 1] = '<div id="stargate-port-modal" class="stargate-node-modal" onclick="if(event.target===this)stargateCloseNodeModal(this)">'
  html[#html + 1] = '<div class="stargate-node-dialog">'
  html[#html + 1] = '<div class="stargate-node-dialog-head"><div class="stargate-node-dialog-title" id="stargate-port-modal-title">' .. ui_text("Configure dedicated port", "配置独立端口") .. '</div><button class="cbi-button stargate-node-x" type="button" onclick="stargateCloseNodeModal(this)">&times;</button></div>'
  html[#html + 1] = '<div class="stargate-node-dialog-body">'
  html[#html + 1] = '<div class="stargate-node-grid">'
  html[#html + 1] = '<div class="stargate-node-field"><label>' .. ui_text("Port purpose / remark", "端口用途 / 备注") .. '</label><input id="stargate_input_port_label" name="port_label" placeholder="' .. ui_text("e.g. Living room TV / Workstation", "例如：客厅电视 / 工作机") .. '" /></div>'
  html[#html + 1] = '<div class="stargate-node-field"><label>' .. ui_text("Bind egress node", "绑定出口节点") .. '</label><select id="stargate_port_node_select" onchange="stargateOnPortNodeChange(this)">' .. node_options_html .. '</select></div>'
  html[#html + 1] = '<div class="stargate-node-field"><label>' .. ui_text("Dedicated SOCKS port", "独立 SOCKS 端口") .. '</label><input id="stargate_input_port_socks" name="port_socks" oninput="stargateCheckPortConflict()" placeholder="' .. def_socks .. '" /></div>'
  html[#html + 1] = '<div class="stargate-node-field"><label>' .. ui_text("Dedicated HTTP port", "独立 HTTP 端口") .. '</label><input id="stargate_input_port_http" name="port_http" oninput="stargateCheckPortConflict()" placeholder="' .. def_http .. '" /></div>'
  html[#html + 1] = '<div class="stargate-node-field" style="grid-column:1/-1"><label>' .. ui_text("Listen address", "监听地址") .. '</label><input id="stargate_input_port_listen" name="port_listen" value="0.0.0.0" /><div class="stargate-node-meta">' .. ui_text("0.0.0.0 listens on every interface (LAN accessible); 127.0.0.1 is local only. Keep WAN input closed in the firewall.", "0.0.0.0 会监听所有接口供局域网设备使用（推荐），127.0.0.1 仅本机可用。请保持防火墙 WAN 入站关闭。") .. '</div></div>'
  html[#html + 1] = '<div id="stargate_port_conflict_warn" style="display:none;color:#f87171;font-size:12px;margin-top:4px;grid-column:1/-1"></div>'
  html[#html + 1] = '</div>'
  html[#html + 1] = '<div class="stargate-node-dialog-actions"><button class="cbi-button" type="button" onclick="stargateCloseNodeModal(this)">' .. ui_text("Cancel", "取消") .. '</button><button class="cbi-button cbi-button-apply" id="stargate_btn_port_save" type="submit" onclick="document.getElementById(\'stargate_node_action\').value=\'port-set\'">' .. ui_text("Save", "保存") .. '</button></div>'
  html[#html + 1] = '</div></div></div>'

  -- Client-side JavaScript for Dedicated Ports
  local existing_ports_json = {}
  for _, item in ipairs(all_nodes) do
    if item.enable_port == "1" then
      existing_ports_json[#existing_ports_json + 1] = string.format(
        '{id:%s,label:%s,socks:%s,http:%s}',
        js_literal(item.id),
        js_literal(item.label),
        js_literal(item.socks_port or ""),
        js_literal(item.http_port or "")
      )
    end
  end

  html[#html + 1] = '<script type="text/javascript">'
  html[#html + 1] = '//<![CDATA['
  html[#html + 1] = 'var stargateExistingPorts=[' .. table.concat(existing_ports_json, ",") .. '];'
  html[#html + 1] = 'var stargateAllNodesCount=' .. #all_nodes .. ';'

  html[#html + 1] = 'function stargateOnPortNodeChange(sel){'
  html[#html + 1] = '  stargateSetValue("stargate_port_node_id", sel.value);'
  html[#html + 1] = '  stargateCheckPortConflict();'
  html[#html + 1] = '}'

  html[#html + 1] = 'function stargateCheckPortConflict(){'
  html[#html + 1] = '  var socks = (document.getElementById("stargate_input_port_socks").value || "").trim();'
  html[#html + 1] = '  var http = (document.getElementById("stargate_input_port_http").value || "").trim();'
  html[#html + 1] = '  var warn = document.getElementById("stargate_port_conflict_warn");'
  html[#html + 1] = '  var saveBtn = document.getElementById("stargate_btn_port_save");'
  html[#html + 1] = '  var origNode = (document.getElementById("stargate_port_orig_node_id").value || "").trim();'
  html[#html + 1] = '  var err = "";'
  html[#html + 1] = '  if(!socks && !http){ err = "' .. ui_text("At least one port (SOCKS or HTTP) is required.", "至少需要填入一个端口（SOCKS 或 HTTP）。") .. '"; }'
  html[#html + 1] = '  else if(socks && http && socks === http){ err = "' .. ui_text("SOCKS and HTTP ports cannot be the same.", "SOCKS 端口与 HTTP 端口不能相同。") .. '"; }'
  html[#html + 1] = '  var portsToCheck = [];'
  html[#html + 1] = '  if(socks){ var sNum = Number(socks); if(!/^[1-9][0-9]*$/.test(socks) || sNum > 65535){ err = "' .. ui_text("Invalid SOCKS port (1-65535).", "SOCKS 端口无效（必须为 1-65535）。") .. '"; } else { portsToCheck.push({port: socks, name: "SOCKS"}); } }'
  html[#html + 1] = '  if(http){ var hNum = Number(http); if(!/^[1-9][0-9]*$/.test(http) || hNum > 65535){ err = "' .. ui_text("Invalid HTTP port (1-65535).", "HTTP 端口无效（必须为 1-65535）。") .. '"; } else { portsToCheck.push({port: http, name: "HTTP"}); } }'
  html[#html + 1] = '  if(!err){'
  html[#html + 1] = '    var mainSocks = "' .. uci_get("inbound", "socks_port", "10808") .. '";'
  html[#html + 1] = '    var mainHttp = "' .. uci_get("inbound", "http_port", "10809") .. '";'
  html[#html + 1] = '    var transPort = "' .. uci_get("inbound", "transparent_port", "12345") .. '";'
  html[#html + 1] = '    var dnsPort = "' .. uci_get("dns", "hijack_port", "1053") .. '";'
  html[#html + 1] = '    var reserved = { [mainSocks]: "' .. ui_text("Main SOCKS", "主 SOCKS 端口") .. '", [mainHttp]: "' .. ui_text("Main HTTP", "主 HTTP 端口") .. '", [transPort]: "' .. ui_text("Transparent proxy", "透明代理端口") .. '", [dnsPort]: "' .. ui_text("DNS hijack", "DNS 劫持端口") .. '" };'
  html[#html + 1] = '    for(var i=0; i<portsToCheck.length; i++){'
  html[#html + 1] = '      var p = portsToCheck[i].port;'
  html[#html + 1] = '      if(reserved[p]){ err = "' .. ui_text("Port", "端口") .. ' " + p + " ' .. ui_text("conflicts with", "与") .. ' " + reserved[p] + " ' .. ui_text("conflict", "冲突。") .. '"; break; }'
  html[#html + 1] = '      for(var j=0; j<stargateExistingPorts.length; j++){'
  html[#html + 1] = '        var ep = stargateExistingPorts[j];'
  html[#html + 1] = '        if(ep.id === origNode) continue;'
  html[#html + 1] = '        if(ep.socks === p || ep.http === p){ err = "' .. ui_text("Port", "端口") .. ' " + p + " ' .. ui_text("is already occupied by node", "已被节点") .. ' [" + ep.label + "] ' .. ui_text("occupied", "占用。") .. '"; break; }'
  html[#html + 1] = '      }'
  html[#html + 1] = '      if(err) break;'
  html[#html + 1] = '    }'
  html[#html + 1] = '  }'
  html[#html + 1] = '  if(err){ warn.innerText = err; warn.style.display = "block"; if(saveBtn) saveBtn.disabled = true; }'
  html[#html + 1] = '  else { warn.innerText = ""; warn.style.display = "none"; if(saveBtn) saveBtn.disabled = false; }'
  html[#html + 1] = '}'

  html[#html + 1] = 'function stargateOpenAddPortModal(defSocks, defHttp){'
  html[#html + 1] = '  if(stargateAllNodesCount === 0){ alert("' .. ui_text("Please add a node above first.", "请先在上方添加节点。") .. '"); return; }'
  html[#html + 1] = '  stargateSetValue("stargate_port_node_id", "");'
  html[#html + 1] = '  stargateSetValue("stargate_port_orig_node_id", "");'
  html[#html + 1] = '  var sel = document.getElementById("stargate_port_node_select");'
  html[#html + 1] = '  var availableCount = 0; var firstVal = "";'
  html[#html + 1] = '  if(sel){'
  html[#html + 1] = '    for(var i=0; i<sel.options.length; i++){'
  html[#html + 1] = '      var opt = sel.options[i];'
  html[#html + 1] = '      var assigned = opt.getAttribute("data-assigned") === "1";'
  html[#html + 1] = '      opt.disabled = assigned;'
  html[#html + 1] = '      if(!assigned){ availableCount++; if(!firstVal) firstVal = opt.value; }'
  html[#html + 1] = '    }'
  html[#html + 1] = '    if(availableCount === 0){ alert("' .. ui_text("All nodes already have dedicated ports assigned. You can edit existing ports or add a new node first.", "所有节点均已分配独立端口。如需更改请编辑已有端口，或先在上方添加新节点。") .. '"); return; }'
  html[#html + 1] = '    sel.value = firstVal;'
  html[#html + 1] = '    stargateSetValue("stargate_port_node_id", firstVal);'
  html[#html + 1] = '  }'
  html[#html + 1] = '  stargateSetValue("stargate_input_port_label", "");'
  html[#html + 1] = '  stargateSetValue("stargate_input_port_socks", defSocks || "");'
  html[#html + 1] = '  stargateSetValue("stargate_input_port_http", defHttp || "");'
  html[#html + 1] = '  stargateSetValue("stargate_input_port_listen", "0.0.0.0");'
  html[#html + 1] = '  var t = document.getElementById("stargate-port-modal-title");'
  html[#html + 1] = '  if(t) t.innerText = "' .. ui_text("Add dedicated port", "添加独立端口") .. '";'
  html[#html + 1] = '  stargateCheckPortConflict();'
  html[#html + 1] = '  stargateOpenNodeModal("stargate-port-modal");'
  html[#html + 1] = '}'

  html[#html + 1] = 'function stargateEditPortModal(nodeId, socks, http, listen, portLabel){'
  html[#html + 1] = '  stargateSetValue("stargate_port_node_id", nodeId);'
  html[#html + 1] = '  stargateSetValue("stargate_port_orig_node_id", nodeId);'
  html[#html + 1] = '  var sel = document.getElementById("stargate_port_node_select");'
  html[#html + 1] = '  if(sel){'
  html[#html + 1] = '    for(var i=0; i<sel.options.length; i++){'
  html[#html + 1] = '      var opt = sel.options[i];'
  html[#html + 1] = '      var assigned = (opt.getAttribute("data-assigned") === "1") && (opt.value !== nodeId);'
  html[#html + 1] = '      opt.disabled = assigned;'
  html[#html + 1] = '    }'
  html[#html + 1] = '    sel.value = nodeId;'
  html[#html + 1] = '  }'
  html[#html + 1] = '  stargateSetValue("stargate_input_port_label", portLabel || "");'
  html[#html + 1] = '  stargateSetValue("stargate_input_port_socks", socks || "");'
  html[#html + 1] = '  stargateSetValue("stargate_input_port_http", http || "");'
  html[#html + 1] = '  stargateSetValue("stargate_input_port_listen", listen || "0.0.0.0");'
  html[#html + 1] = '  var t = document.getElementById("stargate-port-modal-title");'
  html[#html + 1] = '  if(t) t.innerText = "' .. ui_text("Edit dedicated port", "编辑独立端口") .. '";'
  html[#html + 1] = '  stargateCheckPortConflict();'
  html[#html + 1] = '  stargateOpenNodeModal("stargate-port-modal");'
  html[#html + 1] = '}'

  html[#html + 1] = 'document.addEventListener("click", function(e){'
  html[#html + 1] = '  var btn = e.target;'
  html[#html + 1] = '  while(btn && btn.tagName !== "BUTTON"){ btn = btn.parentNode; }'
  html[#html + 1] = '  if(!btn) return;'
  html[#html + 1] = '  var act = btn.getAttribute("data-stargate-action");'
  html[#html + 1] = '  if(act === "port-remove"){'
  html[#html + 1] = '    var pnode = btn.getAttribute("data-port-node");'
  html[#html + 1] = '    var conf = btn.getAttribute("data-confirm");'
  html[#html + 1] = '    if(conf && !confirm(conf)) return;'
  html[#html + 1] = '    stargateSetValue("stargate_port_node_id", pnode);'
  html[#html + 1] = '    stargateSetValue("stargate_node_action", "port-remove");'
  html[#html + 1] = '    var f = btn.form || document.querySelector("form");'
  html[#html + 1] = '    if(f) f.submit();'
  html[#html + 1] = '  }'
  html[#html + 1] = '});'
  html[#html + 1] = '//]]>'
  html[#html + 1] = '</script>'
  html[#html + 1] = '</div>'
  return table.concat(html, "\n")
end

return m
