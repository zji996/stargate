local sys = require "luci.sys"
local util = require "luci.util"
local dispatcher = require "luci.dispatcher"

m = Map("stargate", translate("Stargate"))
m.description = translate("Runtime status and local outlet checks.")

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

s = m:section(NamedSection, "global", "global", translate("Overview"))
s.anonymous = true

dash = s:option(DummyValue, "_dashboard", "")
dash.rawhtml = true
function dash.cfgvalue()
  local version = trim(sys.exec("/usr/bin/sing-box version 2>/dev/null | head -1"))
  local enabled = trim(sys.exec("/etc/init.d/stargate enabled >/dev/null 2>&1 && echo enabled || echo disabled"))
  local running = trim(sys.exec("pgrep -af 'sing-box run -c /etc/stargate' >/dev/null 2>&1 && echo running || echo stopped"))
  local socks = trim(sys.exec("uci -q get stargate.inbound.socks_listen 2>/dev/null || echo 127.0.0.1"))
  local socks_port = trim(sys.exec("uci -q get stargate.inbound.socks_port 2>/dev/null || echo 10808"))
  local http_listen = trim(sys.exec("uci -q get stargate.inbound.http_listen 2>/dev/null || echo 127.0.0.1"))
  local http_port = trim(sys.exec("uci -q get stargate.inbound.http_port 2>/dev/null || echo 10809"))
  local node = trim(sys.exec("uci -q get stargate.node.server 2>/dev/null || echo unset"))
  local connect_url = dispatcher.build_url("admin", "services", "stargate", "connect_status")
  local touch_check = ui_text("Touch Check", "点击检测")
  local checking = ui_text("Check...", "检测中...")
  local problem = ui_text("Problem detected!", "检测异常")
  local direct_outlet = ui_text("Direct local outlet", "本机直连出口")

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

  return table.concat({
    '<style>',
    '#cbi-stargate-global-_dashboard{display:block;margin:0;padding:0;border:0}',
    '#cbi-stargate-global-_dashboard>.cbi-value-title{display:none}',
    '#cbi-stargate-global-_dashboard>.cbi-value-field{display:block;margin:0;width:100%}',
    '.stargate-wrap{max-width:1180px;margin:0 auto;padding:4px 4px 12px}',
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
    '.stargate-ok{color:#2dce89}.stargate-warn{color:#fb9a05}.stargate-bad{color:#fb6340}.stargate-muted{color:#8898aa}',
    '@media screen and (max-width:1180px){.stargate-dashboard{grid-template-columns:repeat(2,minmax(220px,1fr))}.stargate-probes{grid-template-columns:repeat(3,minmax(180px,1fr))}}',
    '@media screen and (max-width:720px){.stargate-dashboard,.stargate-probes{grid-template-columns:1fr}.stargate-card{min-height:84px}}',
    '</style>',
    '<div class="stargate-wrap">',
    '<div class="stargate-dashboard">',
    card(ui_text("Runtime", "运行状态"), running, enabled, nil, "S"),
    card("sing-box", version ~= "" and version or translate("not detected"), "/usr/bin/sing-box", nil, "SB"),
    card(ui_text("Local proxy", "本机代理"), socks .. ":" .. socks_port, "HTTP " .. http_listen .. ":" .. http_port, nil, "P"),
    card(ui_text("Node", "节点"), node, ui_text("AnyTLS primary", "AnyTLS 主节点"), nil, "N"),
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
    'function stargateCheckConnect(target){stargateSetProbe(target,"' .. checking .. '","' .. direct_outlet .. '","stargate-muted");XHR.get("' .. connect_url .. '",{target:target},function(x,rv){if(!rv){stargateSetProbe(target,"' .. problem .. '","XHR failed","stargate-bad");return;}var ms=rv.use_time||0;var dev=rv.dev?(" dev "+rv.dev):"";var src=rv.src?(" src "+rv.src):"";var note="HTTP "+(rv.code||0)+dev+src;if(rv.ok){stargateSetProbe(target,ms+" ms",note,stargateProbeClass(ms,true));}else{stargateSetProbe(target,"' .. problem .. '",(rv.message||"failed")+" "+note,"stargate-bad");}});}',
    '//]]>',
    '</script>'
  }, "\n")
end

enabled = s:option(Flag, "enabled", translate("Enable"))
enabled.rmempty = false

return m
