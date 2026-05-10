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

m = Map("stargate", ui_text("Component Settings", "组件设置"))
m.description = ui_text("Manage sing-box component paths and explicit config lifecycle actions.", "管理 sing-box 组件路径和显式配置生命周期操作。")

local action = http.formvalue("stargate_action")
if action == "generate" or action == "check" or action == "apply" or action == "rollback" then
  m.message = "<pre>" .. util.pcdata(sys.exec("/usr/share/stargate/stargate.sh " .. action .. " 2>&1")) .. "</pre>"
elseif action == "restart" then
  m.message = "<pre>" .. util.pcdata(sys.exec("/etc/init.d/stargate restart 2>&1")) .. "</pre>"
end

ops = m:section(NamedSection, "global", "global", ui_text("Runtime maintenance", "运行维护"))
ops.anonymous = true

log_level = ops:option(ListValue, "log_level", translate("Log level"))
log_level:value("debug", "debug")
log_level:value("info", "info")
log_level:value("warn", "warn")
log_level:value("error", "error")
log_level.default = "warn"

singbox_bin = ops:option(Value, "singbox_bin", translate("sing-box binary"))
singbox_bin.default = "/usr/bin/sing-box"

config_file = ops:option(Value, "config_file", translate("Generated config"))
config_file.default = "/etc/stargate/config.json"

work_dir = ops:option(Value, "work_dir", translate("Work directory"))
work_dir.default = "/etc/stargate"

actions = ops:option(DummyValue, "_actions", ui_text("Maintenance actions", "维护操作"))
actions.rawhtml = true
function actions.cfgvalue()
  local base = dispatcher.build_url("admin", "services", "stargate", "component")
  local node_ready = trim(sys.exec("uci -q get stargate.node.server 2>/dev/null")) ~= "" and trim(sys.exec("uci -q get stargate.node.password 2>/dev/null")) ~= ""
  local blocked_note = ui_text("Blocked until an active node is configured on the Node page.", "需要先在节点页配置当前节点后才能执行。")
  local rows = {
    {
      "generate",
      translate("Generate"),
      ui_text("Build the next sing-box config from UCI. It only writes the staging file and does not start the service.", "从 UCI 生成下一份 sing-box 配置，只写入待校验文件，不启动服务。"),
      true
    },
    {
      "check",
      translate("Check"),
      ui_text("Run sing-box check against the staging config before it becomes active.", "对待校验配置运行 sing-box check，确认通过后再作为正式配置使用。"),
      true
    },
    {
      "apply",
      translate("Apply"),
      ui_text("Validate and replace the active config. It does not enable transparent proxy or change firewall rules.", "校验并替换当前正式配置，不启用透明代理，也不改防火墙规则。"),
      true
    },
    {
      "restart",
      translate("Restart"),
      ui_text("Restart only the Stargate sing-box service with the current active config.", "仅使用当前正式配置重启 Stargate 的 sing-box 服务。"),
      true
    },
    {
      "rollback",
      ui_text("Rollback", "回滚"),
      ui_text("Restore the last backup config created before Apply. If Stargate is running, it restarts with the restored config.", "恢复上一次应用前备份的配置。如果 Stargate 正在运行，会用恢复后的配置重启。"),
      false
    }
  }
  local html = {
    '<style>',
    '.stargate-component-actions{display:grid;gap:10px;max-width:920px}',
    '.stargate-component-action{display:grid;grid-template-columns:120px 1fr;gap:12px;align-items:center;padding:12px;border-top:1px solid rgba(127,127,127,.18)}',
    '.stargate-component-note{font-size:12px;opacity:.76;line-height:1.45}',
    '@media screen and (max-width:720px){.stargate-component-action{grid-template-columns:1fr}}',
    '</style>',
    '<div class="stargate-component-actions">'
  }
  for _, row in ipairs(rows) do
    local disabled = (row[4] and not node_ready) and " disabled" or ""
    html[#html + 1] = '<div class="stargate-component-action">'
    html[#html + 1] = '<input class="cbi-button cbi-button-apply" type="button" value="' .. row[2] .. '"' .. disabled .. ' onclick="location.href=\'' .. base .. '?stargate_action=' .. row[1] .. '\'" />'
    html[#html + 1] = '<div class="stargate-component-note">' .. row[3] .. ((row[4] and not node_ready) and ('<br /><strong>' .. blocked_note .. '</strong>') or "") .. '</div>'
    html[#html + 1] = '</div>'
  end
  html[#html + 1] = '</div>'
  return table.concat(html, "\n")
end

return m
