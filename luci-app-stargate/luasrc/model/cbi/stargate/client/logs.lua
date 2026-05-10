local sys = require "luci.sys"
local util = require "luci.util"

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

m = Map("stargate", ui_text("Logs", "日志"))
m.description = ui_text("Recent Stargate and sing-box logs.", "最近的 Stargate 和 sing-box 日志。")

s = m:section(NamedSection, "global", "global", ui_text("Recent logs", "最近日志"))
s.anonymous = true

logs = s:option(DummyValue, "_logs", "")
logs.rawhtml = true
function logs.cfgvalue()
  local output = sys.exec("/usr/share/stargate/stargate.sh logs 2>/dev/null")
  if trim(output) == "" then
    output = ui_text("No logs", "没有日志")
  end
  return table.concat({
    '<style>',
    '#cbi-stargate-global-_logs>.cbi-value-title{display:none}',
    '#cbi-stargate-global-_logs>.cbi-value-field{display:block;margin:0;width:100%}',
    '.stargate-log-box{white-space:pre-wrap;overflow:auto;max-height:560px;margin:0;padding:14px;border:1px solid rgba(127,127,127,.28);border-radius:6px;background:rgba(0,0,0,.16);font-size:12px;line-height:1.55}',
    '</style>',
    '<pre class="stargate-log-box">' .. util.pcdata(output) .. '</pre>'
  }, "\n")
end

return m
