local sys = require "luci.sys"
local util = require "luci.util"
local http = require "luci.http"
local dispatcher = require "luci.dispatcher"
local common = require "luci.model.stargate.common"

local trim = common.trim
local ui_text = common.ui_text

m = Map("stargate", ui_text("Logs", "日志"))
m.description = ui_text("Recent Stargate and sing-box logs.", "最近的 Stargate 和 sing-box 日志。")

local action = http.formvalue("stargate_logs_action")
if action == "clear" then
  m.message = trim(sys.exec("/usr/share/stargate/stargate.sh logs-clear 2>&1"))
end

s = m:section(NamedSection, "global", "global", ui_text("Recent logs", "最近日志"))
s.anonymous = true

logs = s:option(DummyValue, "_logs", "")
logs.rawhtml = true
function logs.cfgvalue()
  local raw = http.formvalue("raw") == "1"
  local base = dispatcher.build_url("admin", "services", "stargate", "logs")
  local output = sys.exec(raw and "/usr/share/stargate/stargate.sh logs-raw 2>/dev/null" or "/usr/share/stargate/stargate.sh logs 2>/dev/null")
  if trim(output) == "" then
    output = ui_text("No logs", "没有日志")
  end
  return table.concat({
    '<style>',
    '#cbi-stargate-global-_logs>.cbi-value-title{display:none}',
    '#cbi-stargate-global-_logs>.cbi-value-field{display:block;margin:0;width:100%}',
    '.stargate-log-actions{display:flex;gap:10px;flex-wrap:wrap;justify-content:flex-end;margin:0 0 12px}',
    '.stargate-log-box{white-space:pre-wrap;overflow:auto;max-height:560px;margin:0;padding:14px;border:1px solid rgba(127,127,127,.28);border-radius:6px;background:rgba(0,0,0,.16);font-size:12px;line-height:1.55}',
    '</style>',
    '<div class="stargate-log-actions">',
    '<a class="cbi-button" href="' .. base .. '">' .. ui_text("Filtered logs", "过滤日志") .. '</a>',
    '<a class="cbi-button" href="' .. base .. '?raw=1">' .. ui_text("Raw logs", "原始日志") .. '</a>',
    '<a class="cbi-button cbi-button-reset" href="' .. base .. '?stargate_logs_action=clear">' .. ui_text("Clear logs", "清理日志") .. '</a>',
    '</div>',
    '<pre class="stargate-log-box">' .. util.pcdata(output) .. '</pre>'
  }, "\n")
end

return m
