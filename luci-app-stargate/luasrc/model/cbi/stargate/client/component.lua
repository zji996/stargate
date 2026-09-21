local sys = require "luci.sys"
local http = require "luci.http"
local util = require "luci.util"
local dispatcher = require "luci.dispatcher"
local common = require "luci.model.stargate.common"

local trim = common.trim
local ui_text = common.ui_text

m = Map("stargate", ui_text("Maintenance", "维护"))
common.prepare_map(m)
m.description = ui_text("Maintain sing-box paths, future component upgrades, and Stargate backup restore.", "维护 sing-box 路径、后续组件升级和 Stargate 备份还原。")

local action = common.action("stargate_action")
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
    '#cbi-stargate .cbi-section{max-width:1040px;margin:0 auto 18px;border-radius:8px;padding:0;overflow:hidden;box-shadow:0 0 .5rem 0 rgba(0,0,0,.22);background:rgba(127,127,127,.06)}',
    '#cbi-stargate .cbi-section>h3{margin:0;padding:16px 22px;font-size:16px;font-weight:700;line-height:1.3;background:rgba(127,127,127,.14);border-bottom:1px solid rgba(127,127,127,.12);color:inherit}',
    '#cbi-stargate .cbi-section-node{padding:0;margin:0;display:flex;flex-direction:column;gap:0}',
    '#cbi-stargate-global-_style{display:none!important}',
    '.stargate-maint-row{display:flex;align-items:center;min-height:64px;box-sizing:border-box;margin:0;padding:14px 22px;border-top:1px solid rgba(127,127,127,.12);width:100%}',
    '.stargate-maint-row:first-of-type{border-top:0}',
    '#cbi-stargate .cbi-value:not(#cbi-stargate-global-_style):not(#cbi-stargate-safety-_actions){display:flex!important;align-items:center!important;min-height:64px!important;box-sizing:border-box!important;margin:0!important;padding:14px 22px!important;border:0!important;border-top:1px solid rgba(127,127,127,.12)!important;width:100%!important;max-width:none!important;line-height:normal!important;background:none!important}',
    '#cbi-stargate .cbi-value>.cbi-value-title,#cbi-stargate .stargate-maint-label{float:none!important;position:static!important;display:block!important;width:200px!important;min-width:200px!important;max-width:200px!important;padding:0!important;margin:0!important;text-align:left!important;font-size:14px!important;font-weight:600!important;color:inherit!important;word-wrap:break-word!important}',
    '#cbi-stargate .cbi-value>.cbi-value-field,#cbi-stargate .stargate-maint-control{float:none!important;position:static!important;display:flex!important;align-items:center!important;gap:10px!important;flex:1 1 auto!important;min-width:0!important;padding:0!important;margin:0!important;width:auto!important}',
    '#cbi-stargate .cbi-value-field>div[data-ui-widget]{width:100%;max-width:480px}',
    '#cbi-stargate .cbi-value-field input[type="text"]{width:100%!important;max-width:480px!important;min-width:0!important;box-sizing:border-box!important}',
    '#cbi-stargate .cbi-value-description{display:none!important}',
    '.stargate-inline-form{display:flex;align-items:center;gap:10px;flex-wrap:wrap;width:100%}',
    '.stargate-inline-form input[type="file"],.stargate-maint-control input[type="file"]{max-width:320px;box-sizing:border-box}',
    '.stargate-maint-panel{width:100%}',
    '.stargate-maint-control .cbi-button,.stargate-maint-control a.cbi-button{min-width:110px;text-align:center;box-sizing:border-box}',
    '.stargate-maint-version{font-family:monospace;font-size:13.5px;opacity:.82;word-break:break-all}',
    '@media screen and (max-width:768px){',
    '  #cbi-stargate .cbi-value:not(#cbi-stargate-global-_style):not(#cbi-stargate-safety-_actions),.stargate-maint-row{flex-direction:column!important;align-items:flex-start!important;gap:8px!important;padding:12px 16px!important}',
    '  #cbi-stargate .cbi-value>.cbi-value-title,#cbi-stargate .stargate-maint-label{width:100%!important;max-width:none!important;margin-bottom:4px!important}',
    '  #cbi-stargate .cbi-value>.cbi-value-field,#cbi-stargate .stargate-maint-control{width:100%!important;flex-wrap:wrap!important}',
    '  #cbi-stargate .cbi-value-field>div[data-ui-widget],#cbi-stargate .cbi-value-field input[type="text"],.stargate-inline-form input[type="file"],.stargate-maint-control input[type="file"]{max-width:100%!important}',
    '}',
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
    '<div class="stargate-inline-form">',
    '<input type="file" id="stargate-binary" aria-label="' .. ui_text("sing-box binary", "sing-box 文件") .. '" />',
    '<button class="cbi-button cbi-button-action" type="button" data-upload-url="' .. upgrade_url .. '" data-file="stargate-binary" data-file-field="binary" data-upload-action="upgrade" data-confirm="' .. ui_text("Replace sing-box with this file?", "使用此文件替换 sing-box？") .. '">' .. ui_text("Upload upgrade", "上传升级") .. '</button>',
    '<button class="cbi-button" type="button" data-field="stargate_action" data-stargate-action="singbox-rollback" data-confirm="' .. ui_text("Rollback sing-box?", "回滚 sing-box？") .. '">' .. ui_text("Rollback", "执行回滚") .. '</button>',
    '</div>'
  }, "")
end

backup = m:section(NamedSection, "safety", "safety", ui_text("Backup restore", "备份还原"))
backup.anonymous = true

actions = backup:option(DummyValue, "_actions", "")
actions.rawhtml = true
function actions.cfgvalue()
  local base = dispatcher.build_url("admin", "services", "stargate", "component")
  local download_url = dispatcher.build_url("admin", "services", "stargate", "backup_download")
  local restore_url = dispatcher.build_url("admin", "services", "stargate", "backup_restore")

  return table.concat({
    '<style>',
    '#cbi-stargate-safety-_actions{display:block!important;margin:0!important;padding:0!important;border:0!important;width:100%!important;line-height:normal!important}',
    '#cbi-stargate-safety-_actions>.cbi-value-title{display:none!important}',
    '#cbi-stargate-safety-_actions>.cbi-value-field{display:block!important;margin:0!important;width:100%!important}',
    '</style>',
    '<div class="stargate-maint-panel">',
    '<div class="stargate-maint-row">',
    '<div class="stargate-maint-label">' .. ui_text("Create backup file", "创建备份文件") .. '</div>',
    '<div class="stargate-maint-control"><a class="cbi-button cbi-button-apply" href="' .. download_url .. '">' .. ui_text("Download backup", "下载备份") .. '</a></div>',
    '</div>',
    '<div class="stargate-maint-row">',
    '<div class="stargate-maint-label">' .. ui_text("Restore backup file", "恢复备份文件") .. '</div>',
    '<div class="stargate-maint-control"><input type="file" id="stargate-archive" aria-label="' .. ui_text("Backup archive", "备份文件") .. '" accept=".tar.gz,.tgz,application/gzip" /><button class="cbi-button cbi-button-action" type="button" data-upload-url="' .. restore_url .. '" data-file="stargate-archive" data-file-field="archive" data-upload-action="restore" data-confirm="' .. ui_text("Replace current configuration with this backup?", "使用此备份替换当前配置？") .. '">' .. ui_text("Restore backup", "恢复备份") .. '</button></div>',
    '</div>',
    '<div class="stargate-maint-row">',
    '<div class="stargate-maint-label">' .. ui_text("Restore default config", "恢复默认配置") .. '</div>',
    '<div class="stargate-maint-control"><button class="cbi-button cbi-button-negative" type="button" data-field="stargate_action" data-stargate-action="reset-defaults" data-confirm="' .. ui_text("Reset Stargate config to defaults and stop the service?", "将 Stargate 配置恢复默认并停止服务？") .. '">' .. ui_text("Reset", "执行重置") .. '</button></div>',
    '</div>',
    '<div class="stargate-maint-row">',
    '<div class="stargate-maint-label">' .. ui_text("Rollback generated config", "回滚生成配置") .. '</div>',
    '<div class="stargate-maint-control"><button class="cbi-button" type="button" data-field="stargate_action" data-stargate-action="rollback" data-confirm="' .. ui_text("Rollback generated configuration?", "回滚生成配置？") .. '">' .. ui_text("Rollback", "执行回滚") .. '</button></div>',
    '</div>',
    '</div>'
  }, "\n")
end

return m
