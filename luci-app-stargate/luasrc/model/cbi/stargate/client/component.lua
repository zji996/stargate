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

m = Map("stargate", ui_text("Maintenance", "维护"))
m.description = ui_text("Maintain sing-box paths, future component upgrades, and Stargate backup restore.", "维护 sing-box 路径、后续组件升级和 Stargate 备份还原。")

local action = http.formvalue("stargate_action")
if action == "rollback" or action == "reset-defaults" or action == "singbox-rollback" then
  m.message = "<pre>" .. util.pcdata(sys.exec("/usr/share/stargate/stargate.sh " .. action .. " 2>&1")) .. "</pre>"
end

s = m:section(NamedSection, "global", "global", ui_text("sing-box settings", "sing-box 设置"))
s.anonymous = true

style = s:option(DummyValue, "_style", "")
style.rawhtml = true
function style.cfgvalue()
  return table.concat({
    '<style>',
    '#cbi-stargate-global{max-width:960px;margin:0 auto 18px;border-radius:6px;overflow:hidden;background:rgba(127,127,127,.06)}',
    '#cbi-stargate-global>legend{display:flex;align-items:center;min-height:58px;box-sizing:border-box;margin:0;padding:0 22px;width:100%;border:0;background:rgba(127,127,127,.14);font-size:22px;font-weight:700}',
    '#cbi-stargate-global .cbi-section-node{padding:0}',
    '#cbi-stargate-global-_style{display:none}',
    '#cbi-stargate-global-singbox_bin,#cbi-stargate-global-_current_version,#cbi-stargate-global-_upgrade_actions{display:grid;grid-template-columns:220px minmax(320px,520px);gap:16px;align-items:center;min-height:72px;box-sizing:border-box;margin:0;padding:14px 22px;border-top:1px solid rgba(127,127,127,.10)}',
    '#cbi-stargate-global-singbox_bin .cbi-value-title,#cbi-stargate-global-_current_version .cbi-value-title,#cbi-stargate-global-_upgrade_actions .cbi-value-title{text-align:right;font-size:15px;font-weight:600}',
    '#cbi-stargate-global-singbox_bin .cbi-value-field,#cbi-stargate-global-_upgrade_note .cbi-value-field{display:block;margin:0;width:auto}',
    '#cbi-stargate-global-singbox_bin .cbi-value-description{display:none}',
    '#cbi-stargate-global-singbox_bin input[type="text"]{width:100%;max-width:520px;box-sizing:border-box}',
    '.stargate-inline-form{display:flex;align-items:center;gap:10px;flex-wrap:wrap}',
    '.stargate-inline-form input[type="file"]{max-width:300px}',
    '.stargate-maint{display:grid;gap:18px;max-width:960px;margin:0 auto 18px}',
    '.stargate-maint-panel{border-radius:6px;overflow:hidden;background:rgba(127,127,127,.06)}',
    '.stargate-maint-head{display:flex;align-items:center;min-height:58px;padding:0 22px;background:rgba(127,127,127,.14)}',
    '.stargate-maint-title{font-size:22px;font-weight:700;line-height:1.2}',
    '.stargate-maint-row{display:grid;grid-template-columns:220px minmax(320px,520px);gap:16px;align-items:center;min-height:72px;padding:14px 22px;border-top:1px solid rgba(127,127,127,.10)}',
    '.stargate-maint-row:nth-child(odd){background:rgba(127,127,127,.045)}',
    '.stargate-maint-label{text-align:right;font-size:15px;font-weight:600}',
    '.stargate-maint-control{display:flex;align-items:center;gap:10px;min-width:0}',
    '.stargate-maint-control input[type="file"]{width:100%;max-width:300px;box-sizing:border-box}',
    '.stargate-maint-control .cbi-button,.stargate-maint-control a.cbi-button{min-width:118px;text-align:center;box-sizing:border-box}',
    '.stargate-maint-version{opacity:.82}',
    '@media screen and (max-width:820px){#cbi-stargate-global-singbox_bin,#cbi-stargate-global-_current_version,#cbi-stargate-global-_upgrade_actions,.stargate-maint-row{grid-template-columns:1fr;gap:8px}#cbi-stargate-global-singbox_bin .cbi-value-title,#cbi-stargate-global-_current_version .cbi-value-title,#cbi-stargate-global-_upgrade_actions .cbi-value-title,.stargate-maint-label{text-align:left}.stargate-maint-control{flex-wrap:wrap}}',
    '</style>'
  }, "\n")
end

singbox_bin = s:option(Value, "singbox_bin", translate("sing-box binary"))
singbox_bin.default = "/usr/bin/sing-box"

current_version = s:option(DummyValue, "_current_version", ui_text("Current version", "当前版本"))
current_version.rawhtml = true
function current_version.cfgvalue()
  local bin = trim(sys.exec("uci -q get stargate.global.singbox_bin 2>/dev/null || echo /usr/bin/sing-box"))
  if bin == "" then
    bin = "/usr/bin/sing-box"
  end
  local version = trim(sys.exec("'" .. bin:gsub("'", "'\\''") .. "' version 2>/dev/null | head -1"))
  if version == "" then
    version = ui_text("not detected", "未检测到")
  end
  return '<span class="stargate-maint-version">' .. util.pcdata(version) .. '</span>'
end

upgrade_actions = s:option(DummyValue, "_upgrade_actions", ui_text("Component upgrades", "组件升级"))
upgrade_actions.rawhtml = true
function upgrade_actions.cfgvalue()
  local base = dispatcher.build_url("admin", "services", "stargate", "component")
  local upgrade_url = dispatcher.build_url("admin", "services", "stargate", "singbox_upgrade")
  return table.concat({
    '<form class="stargate-inline-form" method="post" action="' .. upgrade_url .. '" enctype="multipart/form-data">',
    '<input type="file" name="binary" />',
    '<input type="hidden" name="upgrade" value="1" />',
    '<input class="cbi-button cbi-button-action" type="submit" value="' .. ui_text("Upload upgrade", "上传升级") .. '" />',
    '<input class="cbi-button" type="button" value="' .. ui_text("Rollback", "执行回滚") .. '" onclick="location.href=\'' .. base .. '?stargate_action=singbox-rollback\'" />',
    '</form>'
  }, "")
end

backup = m:section(NamedSection, "global", "global", "")
backup.anonymous = true

actions = backup:option(DummyValue, "_actions", "")
actions.rawhtml = true
function actions.cfgvalue()
  local base = dispatcher.build_url("admin", "services", "stargate", "component")
  local download_url = dispatcher.build_url("admin", "services", "stargate", "backup_download")
  local restore_url = dispatcher.build_url("admin", "services", "stargate", "backup_restore")

  return table.concat({
    '<style>',
    '#cbi-stargate-global-_actions{display:block;margin:0;padding:0;border:0}',
    '#cbi-stargate-global-_actions>.cbi-value-title{display:none}',
    '#cbi-stargate-global-_actions>.cbi-value-field{display:block;margin:0;width:100%}',
    '</style>',
    '<div class="stargate-maint">',
    '<div class="stargate-maint-panel">',
    '<div class="stargate-maint-head"><div class="stargate-maint-title">' .. ui_text("Backup restore", "备份还原") .. '</div></div>',
    '<div class="stargate-maint-row">',
    '<div class="stargate-maint-label">' .. ui_text("Create backup file", "创建备份文件") .. '</div>',
    '<div class="stargate-maint-control"><a class="cbi-button cbi-button-apply" href="' .. download_url .. '">' .. ui_text("Download backup", "下载备份") .. '</a></div>',
    '</div>',
    '<form class="stargate-maint-row" method="post" action="' .. restore_url .. '" enctype="multipart/form-data">',
    '<div class="stargate-maint-label">' .. ui_text("Restore backup file", "恢复备份文件") .. '</div>',
    '<div class="stargate-maint-control"><input type="file" name="archive" accept=".tar.gz,.tgz,application/gzip" /><input type="hidden" name="restore" value="1" /><input class="cbi-button cbi-button-action" type="submit" value="' .. ui_text("Restore backup", "恢复备份") .. '" /></div>',
    '</form>',
    '<div class="stargate-maint-row">',
    '<div class="stargate-maint-label">' .. ui_text("Restore default config", "恢复默认配置") .. '</div>',
    '<div class="stargate-maint-control"><input class="cbi-button cbi-button-negative" type="button" value="' .. ui_text("Reset", "执行重置") .. '" onclick="if(confirm(\'' .. ui_text("Reset Stargate config to defaults and stop the service?", "将 Stargate 配置恢复默认并停止服务？") .. '\')) location.href=\'' .. base .. '?stargate_action=reset-defaults\'" /></div>',
    '</div>',
    '<div class="stargate-maint-row">',
    '<div class="stargate-maint-label">' .. ui_text("Rollback generated config", "回滚生成配置") .. '</div>',
    '<div class="stargate-maint-control"><input class="cbi-button" type="button" value="' .. ui_text("Rollback", "执行回滚") .. '" onclick="location.href=\'' .. base .. '?stargate_action=rollback\'" /></div>',
    '</div>',
    '</div>',
    '</div>',
    '<script type="text/javascript">',
    'document.addEventListener("submit",function(ev){var form=ev.target;if(!form||!form.classList||!form.classList.contains("stargate-maint-row"))return;var file=form.querySelector("input[type=file]");if(!file||!file.value){ev.preventDefault();alert("' .. ui_text("Choose a backup file first.", "请先选择备份文件。") .. '");}});',
    '</script>'
  }, "\n")
end

return m
