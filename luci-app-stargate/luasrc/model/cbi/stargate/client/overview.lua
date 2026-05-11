local sys = require "luci.sys"
local util = require "luci.util"
local dispatcher = require "luci.dispatcher"
local common = require "luci.model.stargate.common"

local trim = common.trim
local shellquote = common.shellquote
local ui_text = common.ui_text

m = Map("stargate", translate("Stargate"))
m.description = translate("Runtime status, proxy mode, and local outlet checks.")

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
  local firewall_active = trim(sys.exec("/usr/share/stargate/stargate.sh firewall-status 2>/dev/null | grep -q '^Active: yes$' && echo 1 || echo 0"))
  local connect_url = dispatcher.build_url("admin", "services", "stargate", "connect_status")
  local touch_check = ui_text("Touch Check", "点击检测")
  local checking = ui_text("Check...", "检测中...")
  local problem = ui_text("Problem detected!", "检测异常")
  local direct_outlet = ui_text("Direct local outlet", "本机直连出口")
  local transparent_outlet = ui_text("Stargate transparent path", "Stargate 透明代理路径")
  local local_outlet = ui_text("Stargate local proxy path", "Stargate 本机代理路径")
  local inactive_forwarding = ui_text("Stargate local proxy path (forwarding inactive)", "Stargate 本机代理路径（透明转发未生效）")
  local stopped_outlet = ui_text("Stargate is not running", "Stargate 未运行")
  local initial_probe_path = stopped_outlet
  if running == "running" then
    if transparent_enabled == "1" and firewall_active == "1" then
      initial_probe_path = transparent_outlet
    elseif transparent_enabled == "1" then
      initial_probe_path = inactive_forwarding
    else
      initial_probe_path = local_outlet
    end
  end

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
      '<span id="stargate-' .. target .. '-note" class="stargate-card-note">' .. util.pcdata(initial_probe_path) .. '</span>' ..
      '</span>' ..
      '</button>'
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
    '.stargate-result{max-width:880px;margin:0 auto 12px;padding:10px 12px;border-radius:6px;background:rgba(46,160,67,.14);color:#8bd48b;white-space:pre-wrap}',
    '#cbi-stargate-global-enabled,#cbi-stargate-inbound-transparent_proxy{max-width:880px;margin:12px auto;padding:14px;border:1px solid rgba(140,140,140,.42);border-radius:6px;background:rgba(127,127,127,.05);display:grid;grid-template-columns:minmax(180px,260px) 1fr;gap:12px;align-items:center}',
    '#cbi-stargate-global-enabled .cbi-value-title,#cbi-stargate-inbound-transparent_proxy .cbi-value-title{font-weight:700}',
    '#cbi-stargate-global-enabled .cbi-value-description,#cbi-stargate-inbound-transparent_proxy .cbi-value-description{display:block;margin-top:5px;font-size:11px;line-height:1.45;opacity:.72}',
    '#cbi-stargate-global-enabled .cbi-value-field,#cbi-stargate-inbound-transparent_proxy .cbi-value-field{display:flex;align-items:center;justify-content:flex-start;min-height:34px}',
    '#cbi-stargate-global-enabled input[type="checkbox"],#cbi-stargate-inbound-transparent_proxy input[type="checkbox"]{width:22px;height:22px;margin:0 10px 0 0;vertical-align:middle}',
    '#cbi-stargate-inbound-transparent_proxy.stargate-disabled{opacity:.58}',
    '#cbi-stargate-inbound-transparent_proxy.stargate-disabled input[type="checkbox"]{cursor:not-allowed}',
    '#cbi-stargate-inbound-transparent_proxy.stargate-disabled .cbi-value-description:after{content:" ' .. ui_text("Enable local proxy first.", "请先勾选本机代理。") .. '";color:#fb9a05}',
    '#cbi-stargate-inbound-transparent_mode,#cbi-stargate-inbound-transparent_port{max-width:880px;margin-left:auto;margin-right:auto}',
    '.stargate-ok{color:#2dce89}.stargate-warn{color:#fb9a05}.stargate-bad{color:#fb6340}.stargate-muted{color:#8898aa}',
    '@media screen and (max-width:1180px){.stargate-dashboard{grid-template-columns:repeat(2,minmax(220px,1fr))}.stargate-probes{grid-template-columns:repeat(3,minmax(180px,1fr))}}',
    '@media screen and (max-width:720px){.stargate-dashboard,.stargate-probes,#cbi-stargate-global-enabled,#cbi-stargate-inbound-transparent_proxy{grid-template-columns:1fr}.stargate-card{min-height:84px}}',
    '</style>',
    '<div class="stargate-wrap">',
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
    '</div>',
    '<script type="text/javascript">',
    '//<![CDATA[',
    'function stargateProbeClass(ms, ok){if(!ok)return "stargate-bad";if(ms<800)return "stargate-ok";if(ms<1800)return "stargate-warn";return "stargate-bad";}',
    'function stargateSetProbe(target, text, note, cls){var s=document.getElementById("stargate-"+target+"-status");var n=document.getElementById("stargate-"+target+"-note");if(s){s.className="stargate-probe-value "+cls;s.innerHTML=text;}if(n){n.innerHTML=note||"";}}',
    'function stargateCheckConnect(target){stargateSetProbe(target,"' .. checking .. '","' .. initial_probe_path .. '","stargate-muted");XHR.get("' .. connect_url .. '",{target:target},function(x,rv){if(!rv){stargateSetProbe(target,"' .. problem .. '","XHR failed","stargate-bad");return;}var ms=rv.use_time||0;var mode=rv.mode==="transparent"?"' .. transparent_outlet .. '":(rv.mode==="local"?(rv.firewall_active===false&&rv.mode_label&&rv.mode_label.indexOf("inactive")>=0?"' .. inactive_forwarding .. '":"' .. local_outlet .. '"):(rv.mode==="stopped"?"' .. stopped_outlet .. '":"' .. direct_outlet .. '"));var dev=rv.dev?(" dev "+rv.dev):"";var src=rv.src?(" src "+rv.src):"";var note=mode+" / HTTP "+(rv.code||0)+dev+src;if(rv.ok){stargateSetProbe(target,ms+" ms",note,stargateProbeClass(ms,true));}else{stargateSetProbe(target,"' .. problem .. '",(rv.message||"failed")+" / "+note,"stargate-bad");}});}',
    'function stargateRuntimeCheckboxes(){var local=document.querySelector("[name=\'cbid.stargate.global.enabled\'][type=\'checkbox\']");var transparent=document.querySelector("[name=\'cbid.stargate.inbound.transparent_proxy\'][type=\'checkbox\']");var row=document.getElementById("cbi-stargate-inbound-transparent_proxy");if(!local||!transparent)return;var on=!!local.checked;if(!on)transparent.checked=false;if(row){if(on)row.classList.remove("stargate-disabled");else row.classList.add("stargate-disabled");}}',
    'document.addEventListener("DOMContentLoaded",function(){var local=document.querySelector("[name=\'cbid.stargate.global.enabled\'][type=\'checkbox\']");var transparent=document.querySelector("[name=\'cbid.stargate.inbound.transparent_proxy\'][type=\'checkbox\']");if(local)local.addEventListener("change",stargateRuntimeCheckboxes);if(transparent)transparent.addEventListener("change",function(){if(local&&!local.checked)this.checked=false;stargateRuntimeCheckboxes();});stargateRuntimeCheckboxes();});',
    '//]]>',
    '</script>'
  }, "\n")
end

local_proxy = s:option(Flag, "enabled", ui_text("Local proxy", "本机代理"))
local_proxy.description = ui_text("Enable Stargate with local SOCKS/HTTP inbounds only. Use Save & Apply in the bottom-right corner to commit this choice.", "启用 Stargate 本机 SOCKS/HTTP 入站。勾选后使用右下角“保存&应用”提交。")
local_proxy.default = "0"
local_proxy.rmempty = false

mode_section = m:section(NamedSection, "inbound", "inbound", ui_text("Transparent proxy", "透明代理"))
mode_section.anonymous = true

transparent_proxy = mode_section:option(Flag, "transparent_proxy", ui_text("Transparent proxy", "透明代理"))
transparent_proxy.description = ui_text("Optional transparent inbound. Enable local proxy first, then configure forwarding on the Advanced page.", "可选透明入站。需要先勾选本机代理；之后到高级页配置转发。")
transparent_proxy.default = "0"
transparent_proxy.rmempty = false

transparent_mode = mode_section:option(ListValue, "transparent_mode", ui_text("Transparent mode", "透明模式"))
transparent_mode:value("redirect", "redirect")
transparent_mode:value("tproxy", "tproxy")
transparent_mode.default = "redirect"
transparent_mode.rmempty = false
transparent_mode:depends("transparent_proxy", "1")

transparent_port = mode_section:option(Value, "transparent_port", ui_text("Transparent port", "透明代理端口"))
transparent_port.default = "12345"
transparent_port.datatype = "port"
transparent_port:depends("transparent_proxy", "1")

return m
