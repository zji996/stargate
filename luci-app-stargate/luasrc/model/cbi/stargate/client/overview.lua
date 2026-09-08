local sys = require "luci.sys"
local dispatcher = require "luci.dispatcher"
local common = require "luci.model.stargate.common"
local text = common.ui_text
local pc = common.pc

m = Map("stargate", "Stargate")
common.prepare_map(m)
s = m:section(NamedSection, "global", "global", text("Overview", "概览"))
s.anonymous = true
local dashboard = s:option(DummyValue, "_dashboard", "")
dashboard.rawhtml = true
function dashboard.cfgvalue()
  local running = sys.call("/etc/init.d/stargate status >/dev/null 2>&1") == 0
  local ready = sys.call("test -n \"$(uci -q get stargate.node.server)\" && test -n \"$(uci -q get stargate.node.password)\"") == 0
  local bin = common.trim(sys.exec("uci -q get stargate.global.singbox_bin"))
  if bin == "" then bin = "/usr/bin/sing-box" end
  local version = common.trim(sys.exec(common.shellquote(bin) .. " version 2>/dev/null | head -1")):match("version%s+(%S+)") or "—"
  local result = {
    '<link rel="stylesheet" href="/luci-static/resources/stargate-overview.css?v=2" />',
    '<script src="/luci-static/resources/stargate-overview.js?v=2" defer></script>',
    '<div class="sg-overview" data-probe-url="' .. pc(dispatcher.build_url("admin", "services", "stargate", "connect_status")) .. '">',
    '<div class="sg-summary"><span class="sg-runtime"><span class="sg-dot ' .. (running and 'sg-dot-on' or '') .. '"></span>' .. text(running and "Running" or "Stopped", running and "运行中" or "未运行") .. '</span><span class="sg-version">sing-box ' .. pc(version) .. '</span></div>',
    ready and '' or '<a class="sg-empty" href="' .. pc(dispatcher.build_url("admin", "services", "stargate", "node")) .. '">' .. text("Add and select a node", "添加并选择节点") .. '</a>',
    '<div class="sg-probes" aria-label="' .. text("Proxy connectivity", "代理连通性") .. '">'
  }
  for _, item in ipairs({{"baidu", text("Baidu", "百度")}, {"google", text("Google", "谷歌")}, {"github", "GitHub"}}) do
    result[#result + 1] = '<button type="button" class="sg-probe" data-target="' .. item[1] .. '" data-checking="' .. text("Checking…", "检测中…") .. '" data-failed="' .. text("Failed", "未连通") .. '"><span>' .. item[2] .. '</span><span class="sg-probe-result" aria-live="polite">' .. text("Check", "检测") .. '</span></button>'
  end
  result[#result + 1] = '</div></div>'
  return table.concat(result, "\n")
end

local enabled = s:option(Flag, "enabled", text("Enable Stargate", "启用 Stargate"))
enabled.default = "0"
enabled.rmempty = false
local inbound = m:section(NamedSection, "inbound", "inbound", text("Traffic", "流量接管"))
inbound.anonymous = true
local transparent = inbound:option(Flag, "transparent_proxy", text("LAN proxy", "局域网代理"))
transparent.default = "0"
transparent.rmempty = false
local netbird = inbound:option(Flag, "netbird_proxy", text("NetBird exit proxy", "NetBird 出口代理"))
netbird.default = "1"
netbird.rmempty = false
netbird:depends("transparent_proxy", "1")
return m
