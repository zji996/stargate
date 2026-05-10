local sys = require "luci.sys"
local http = require "luci.http"
local util = require "luci.util"
local dispatcher = require "luci.dispatcher"

local function trim(value)
  return (value or ""):gsub("%s+$", "")
end

local function shellquote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

m = Map("stargate", translate("Stargate"))
m.description = translate("Runtime status, startup mode, and local outlet checks.")

local runtime_action = http.formvalue("stargate_runtime_action")
local runtime_output = nil
local runtime_ok = false
if runtime_action == "start" then
  runtime_output = sys.exec("/usr/share/stargate/stargate.sh start 2>&1")
elseif runtime_action == "start-transparent" then
  local mode = trim(http.formvalue("stargate_runtime_mode") or "")
  local port = trim(http.formvalue("stargate_runtime_port") or "")
  if mode == "" then
    mode = trim(sys.exec("uci -q get stargate.inbound.transparent_mode 2>/dev/null || echo redirect"))
  end
  if port == "" then
    port = trim(sys.exec("uci -q get stargate.inbound.transparent_port 2>/dev/null || echo 12345"))
  end
  if mode ~= "tproxy" then
    mode = "redirect"
  end
  if not port:match("^[0-9]+$") then
    port = "12345"
  end
  runtime_output = sys.exec("/usr/share/stargate/stargate.sh start-transparent " .. mode .. " " .. port .. " 2>&1")
elseif runtime_action == "stop" then
  runtime_output = sys.exec("/usr/share/stargate/stargate.sh stop 2>&1")
elseif runtime_action == "rollback" then
  runtime_output = sys.exec("/usr/share/stargate/stargate.sh rollback 2>&1")
end
if runtime_output then
  runtime_ok = not runtime_output:match("[Ee]rror") and not runtime_output:match("[Ff]ailed") and not runtime_output:match("missing") and not runtime_output:match("required") and not runtime_output:match("not found") and not runtime_output:match("no backup")
end

local function ui_text(en, zh)
  local lang = trim(sys.exec("uci -q get luci.main.lang 2>/dev/null || echo auto"))
  if lang == "zh_cn" or lang == "zh-cn" or lang == "zh" or lang == "auto" then
    return zh
  end
  return en
end

local function has_active_node()
  local server = trim(sys.exec("uci -q get stargate.node.server 2>/dev/null"))
  local password = trim(sys.exec("uci -q get stargate.node.password 2>/dev/null"))
  return server ~= "" and password ~= ""
end

s = m:section(NamedSection, "global", "global", translate("Overview"))
s.anonymous = true

dash = s:option(DummyValue, "_dashboard", "")
dash.rawhtml = true
function dash.cfgvalue()
  local singbox_bin = trim(sys.exec("uci -q get stargate.global.singbox_bin 2>/dev/null || echo /usr/bin/sing-box"))
  local config_file = trim(sys.exec("uci -q get stargate.global.config_file 2>/dev/null || echo /etc/stargate/config.json"))
  local backup_file = config_file .. ".bak"
  local version = trim(sys.exec(shellquote(singbox_bin) .. " version 2>/dev/null | head -1"))
  local enabled = trim(sys.exec("/etc/init.d/stargate enabled >/dev/null 2>&1 && echo enabled || echo disabled"))
  local running = trim(sys.exec("pgrep -af 'sing-box run -c' 2>/dev/null | grep -F -- " .. shellquote(config_file) .. " >/dev/null && echo running || echo stopped"))
  local socks = trim(sys.exec("uci -q get stargate.inbound.socks_listen 2>/dev/null || echo 127.0.0.1"))
  local socks_port = trim(sys.exec("uci -q get stargate.inbound.socks_port 2>/dev/null || echo 10808"))
  local http_listen = trim(sys.exec("uci -q get stargate.inbound.http_listen 2>/dev/null || echo 127.0.0.1"))
  local http_port = trim(sys.exec("uci -q get stargate.inbound.http_port 2>/dev/null || echo 10809"))
  local node = trim(sys.exec("uci -q get stargate.node.server 2>/dev/null || echo unset"))
  local node_ready = has_active_node()
  local transparent_enabled = trim(sys.exec("uci -q get stargate.inbound.transparent_proxy 2>/dev/null || echo 0"))
  local transparent_mode = trim(sys.exec("uci -q get stargate.inbound.transparent_mode 2>/dev/null || echo redirect"))
  local backup_ready = sys.call("[ -f " .. shellquote(backup_file) .. " ] >/dev/null 2>&1") == 0
  local connect_url = dispatcher.build_url("admin", "services", "stargate", "connect_status")
  local base = dispatcher.build_url("admin", "services", "stargate", "overview")
  local touch_check = ui_text("Touch Check", "点击检测")
  local checking = ui_text("Check...", "检测中...")
  local problem = ui_text("Problem detected!", "检测异常")
  local direct_outlet = ui_text("Direct local outlet", "本机直连出口")
  local disabled = node_ready and "" or " disabled=\"disabled\""

  local function card(title, value, note, class, icon)
    return '<div class="stargate-card ' .. (class or "") .. '">' ..
      '<div class="stargate-icon stargate-icon-core">' .. util.pcdata(icon or "S") .. '</div>' ..
      '<div class="stargate-card-body">' ..
      '<div class="stargate-card-title">' .. util.pcdata(title) .. '</div>' ..
      '<div class="stargate-card-value">' .. util.pcdata(value) .. '</div>' ..
      '<div class="stargate-card-note">' .. util.pcdata(note or "") .. '</div>' ..
      '</div>' ..
      '</div>'
  end

  local function probe_card(target, title, icon)
    return '<button type="button" class="stargate-card stargate-probe" onclick="stargateCheckConnect(\'' .. target .. '\')">' ..
      '<span class="stargate-icon stargate-icon-' .. target .. '">' .. icon .. '</span>' ..
      '<span class="stargate-card-body">' ..
      '<span class="stargate-card-title">' .. util.pcdata(title) .. '</span>' ..
      '<span id="stargate-' .. target .. '-status" class="stargate-probe-value stargate-muted">' .. util.pcdata(touch_check) .. '</span>' ..
      '<span id="stargate-' .. target .. '-note" class="stargate-card-note">' .. util.pcdata(direct_outlet) .. '</span>' ..
      '</span>' ..
      '</button>'
  end

  local function action_button(action, text, class, disabled_attr)
    return '<input class="cbi-button ' .. (class or "") .. '" type="button" value="' .. util.pcdata(text) .. '"' .. (disabled_attr or "") .. ' onclick="stargateRuntimeAction(\'' .. action .. '\')" />'
  end

  return table.concat({
    '<style>',
    '#cbi-stargate-global-_dashboard{display:block;margin:0;padding:0;border:0}',
    '#cbi-stargate-global-_dashboard>.cbi-value-title{display:none}',
    '#cbi-stargate-global-_dashboard>.cbi-value-field{display:block;margin:0;width:100%}',
    '.stargate-wrap{max-width:1180px;margin:0 auto;padding:4px 4px 8px}',
    '.stargate-dashboard{display:grid;grid-template-columns:repeat(4,minmax(190px,1fr));gap:12px;margin:8px 0 14px}',
    '.stargate-probes{grid-template-columns:repeat(3,minmax(220px,1fr));max-width:880px;margin-left:auto;margin-right:auto}',
    '.stargate-card{box-sizing:border-box;display:flex;align-items:center;gap:13px;min-height:92px;padding:14px 15px;border:1px solid rgba(140,140,140,.72);border-radius:6px;background:rgba(127,127,127,.08);text-align:left;box-shadow:0 6px 18px rgba(0,0,0,.07)}',
    '.stargate-card-body{display:block;min-width:0}',
    '.stargate-card-title{display:block;font-size:12px;opacity:.72}',
    '.stargate-card-value{display:block;font-size:19px;font-weight:700;margin-top:5px;line-height:1.18;word-break:break-word}',
    '.stargate-card-note{display:block;font-size:11px;opacity:.72;margin-top:5px;line-height:1.35}',
    '.stargate-icon{display:flex;align-items:center;justify-content:center;flex:0 0 42px;width:42px;height:42px;border-radius:50%;font-size:18px;font-weight:700;color:#fff;background:#5f6fe6}',
    '.stargate-icon-core{background:#687485}',
    '.stargate-icon-baidu{background:#3357e8}',
    '.stargate-icon-google{background:#db4437}',
    '.stargate-icon-github{background:#111;color:#ddd}',
    '.stargate-probe{cursor:pointer;color:inherit;font:inherit}',
    '.stargate-probe:hover{border-color:#999;background:rgba(127,127,127,.12)}',
    '.stargate-probe-value{display:block;font-size:18px;font-weight:700;margin-top:5px;line-height:1.2}',
    '.stargate-alert{max-width:880px;margin:0 auto 14px;padding:11px 13px;border:1px solid rgba(251,99,64,.55);border-radius:6px;color:#fb6340;background:rgba(251,99,64,.08)}',
    '.stargate-runtime-result{max-width:880px;margin:0 auto 14px;padding:10px 12px;border:1px solid rgba(127,127,127,.22);border-radius:6px;background:rgba(127,127,127,.08)}',
    '.stargate-runtime-result pre{margin:6px 0 0;white-space:pre-wrap}',
    '.stargate-runtime{max-width:880px;margin:12px auto 6px;display:grid;grid-template-columns:minmax(200px,1fr) 2fr;gap:12px;align-items:center;padding:14px;border:1px solid rgba(140,140,140,.42);border-radius:6px;background:rgba(127,127,127,.05)}',
    '.stargate-runtime-title{font-size:13px;font-weight:700}',
    '.stargate-runtime-note{font-size:11px;opacity:.72;margin-top:4px;line-height:1.4}',
    '.stargate-runtime-actions{display:flex;justify-content:flex-end;gap:10px;flex-wrap:wrap}',
    '.stargate-ok{color:#2dce89}.stargate-warn{color:#fb9a05}.stargate-bad{color:#fb6340}.stargate-muted{color:#8898aa}',
    '@media screen and (max-width:1180px){.stargate-dashboard{grid-template-columns:repeat(2,minmax(220px,1fr))}.stargate-probes{grid-template-columns:repeat(3,minmax(180px,1fr))}}',
    '@media screen and (max-width:720px){.stargate-dashboard,.stargate-probes,.stargate-runtime{grid-template-columns:1fr}.stargate-card{min-height:84px}.stargate-runtime-actions{justify-content:flex-start}}',
    '</style>',
    '<div class="stargate-wrap">',
    (runtime_output and ('<div class="stargate-runtime-result ' .. (runtime_ok and 'stargate-ok' or 'stargate-bad') .. '"><strong>' .. ui_text("Operation result", "操作结果") .. '</strong><pre>' .. util.pcdata(trim(runtime_output)) .. '</pre></div>') or ""),
    (node_ready and "" or '<div class="stargate-alert">' .. ui_text("No active node is configured. Add a node on the Node page and choose Use this node before enabling or starting Stargate.", "还没有配置当前节点。请先到节点页添加节点，并点击“使用此节点”，之后才能启用或启动 Stargate。") .. '</div>'),
    '<div class="stargate-dashboard">',
    card(ui_text("Runtime", "运行状态"), node_ready and running or ui_text("not ready", "未就绪"), node_ready and (((transparent_enabled == "1" and (ui_text("transparent", "透明代理") .. " " .. transparent_mode)) or ui_text("local proxy", "本机代理")) .. " / " .. enabled) or ui_text("active node required", "需要当前节点"), nil, "S"),
    card("sing-box", version ~= "" and version or translate("not detected"), singbox_bin, nil, "SB"),
    card(ui_text("Local proxy", "本机代理"), socks .. ":" .. socks_port, "HTTP " .. http_listen .. ":" .. http_port, nil, "P"),
    card(ui_text("Node", "节点"), node_ready and node or ui_text("not ready", "未就绪"), node_ready and ui_text("AnyTLS primary", "AnyTLS 主节点") or ui_text("Add and use a node first", "请先添加并使用节点"), nil, "N"),
    '</div>',
    '<div class="stargate-dashboard stargate-probes">',
    probe_card("baidu", ui_text("Baidu Connection", "百度连接"), "B"),
    probe_card("google", ui_text("Google Connection", "谷歌连接"), "G"),
    probe_card("github", ui_text("GitHub Connection", "GitHub 连接"), "GH"),
    '</div>',
    '<div class="stargate-runtime">',
    '<div><div class="stargate-runtime-title">' .. ui_text("Startup mode", "启动方式") .. '</div><div class="stargate-runtime-note">' .. ui_text("Local proxy keeps only SOCKS/HTTP. Transparent proxy adds a sing-box transparent inbound; redirect is the default.", "本机代理只启动 SOCKS/HTTP。透明代理会额外启动 sing-box 透明入站，默认 redirect。") .. '</div></div>',
    '<div class="stargate-runtime-actions">',
    action_button("start", ui_text("Start local proxy", "启动本机代理"), "cbi-button-apply", disabled),
    action_button("start-transparent", ui_text("Start transparent proxy", "启动透明代理"), "cbi-button-action", disabled),
    action_button("stop", ui_text("Stop", "停止"), "", ""),
    action_button("rollback", ui_text("Rollback config", "回滚配置"), "", backup_ready and "" or ' disabled="disabled"'),
    '</div>',
    '</div>',
    '</div>',
    '<script type="text/javascript">',
    '//<![CDATA[',
    'function stargateProbeClass(ms, ok){if(!ok)return "stargate-bad";if(ms<800)return "stargate-ok";if(ms<1800)return "stargate-warn";return "stargate-bad";}',
    'function stargateSetProbe(target, text, note, cls){var s=document.getElementById("stargate-"+target+"-status");var n=document.getElementById("stargate-"+target+"-note");if(s){s.className="stargate-probe-value "+cls;s.innerHTML=text;}if(n){n.innerHTML=note||"";}}',
    'function stargateCheckConnect(target){stargateSetProbe(target,"' .. checking .. '","' .. direct_outlet .. '","stargate-muted");XHR.get("' .. connect_url .. '",{target:target},function(x,rv){if(!rv){stargateSetProbe(target,"' .. problem .. '","XHR failed","stargate-bad");return;}var ms=rv.use_time||0;var dev=rv.dev?(" dev "+rv.dev):"";var src=rv.src?(" src "+rv.src):"";var note="HTTP "+(rv.code||0)+dev+src;if(rv.ok){stargateSetProbe(target,ms+" ms",note,stargateProbeClass(ms,true));}else{stargateSetProbe(target,"' .. problem .. '",(rv.message||"failed")+" "+note,"stargate-bad");}});}',
    'function stargateRuntimeAction(action){var url="' .. base .. '?stargate_runtime_action="+encodeURIComponent(action);if(action==="start-transparent"){var mode=document.querySelector("[name=\'cbid.stargate.inbound.transparent_mode\']");var port=document.querySelector("[name=\'cbid.stargate.inbound.transparent_port\']");url+="&stargate_runtime_mode="+encodeURIComponent(mode&&mode.value?mode.value:"redirect");url+="&stargate_runtime_port="+encodeURIComponent(port&&port.value?port.value:"12345");}location.href=url;}',
    '//]]>',
    '</script>'
  }, "\n")
end

mode_section = m:section(NamedSection, "inbound", "inbound", ui_text("Transparent proxy", "透明代理"))
mode_section.anonymous = true

transparent_mode = mode_section:option(ListValue, "transparent_mode", ui_text("Transparent mode", "透明模式"))
transparent_mode:value("redirect", "redirect")
transparent_mode:value("tproxy", "tproxy")
transparent_mode.default = "redirect"
transparent_mode.rmempty = false

transparent_port = mode_section:option(Value, "transparent_port", ui_text("Transparent port", "透明代理端口"))
transparent_port.default = "12345"
transparent_port.datatype = "port"

return m
