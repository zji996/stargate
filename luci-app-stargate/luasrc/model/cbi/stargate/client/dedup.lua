local sys = require "luci.sys"
local http = require "luci.http"
local uci = require("luci.model.uci").cursor()
local common = require "luci.model.stargate.common"
local ip = require "luci.ip"
local text = common.ui_text

local form = SimpleForm("stargate_dedup", text("Deduplication", "去重编解码"))
form.submit = false
form.reset = false
local message
if common.action("stargate_dedup_action") == "configure" then
  local enabled = http.formvalue("dedup_enabled") or "0"
  local devices = http.formvalue("dedup_devices")
  local targets = http.formvalue("dedup_targets")
  local valid = (enabled == "0" or enabled == "1")
    and type(devices) == "string" and #devices <= 4096
    and type(targets) == "string" and #targets <= 4096
  if valid then
    for device in devices:gmatch("[^%s,]+") do
      local ok, address = pcall(ip.new, device)
      if not ok or not address then valid = false end
    end
  end
  if valid then
    message = sys.exec("/usr/share/stargate/dedup.sh configure " .. common.shellquote(enabled)
      .. " " .. common.shellquote(devices) .. " " .. common.shellquote(targets) .. " 2>&1")
  else
    message = text("Invalid devices or targets.", "设备或目标格式无效，请填写有效的 IP、网段和域名。")
  end
end

local section = form:section(SimpleSection)
section.template = "stargate/dedup"
section.dedup_message = message
section.dedup_enabled = uci:get("stargate", "dedup", "enabled") == "1"
section.dedup_devices = uci:get("stargate", "dedup", "devices") or ""
section.dedup_domains = uci:get("stargate", "dedup", "domains") or "chatgpt.com api.openai.com"
section.dedup_targets = uci:get("stargate", "dedup", "targets") or section.dedup_domains
if section.dedup_targets == "none" then section.dedup_targets = "" end
section.dedup_status = sys.exec("/usr/share/stargate/dedup.sh status 2>&1")
return form
