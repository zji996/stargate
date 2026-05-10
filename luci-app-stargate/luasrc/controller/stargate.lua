module("luci.controller.stargate", package.seeall)

function index()
  if not nixio.fs.access("/etc/config/stargate") then
    return
  end

  local page = entry({"admin", "services", "stargate"}, alias("admin", "services", "stargate", "overview"), _("Stargate"), 61)
  page.dependent = true
  page.acl_depends = { "luci-app-stargate" }

  entry({"admin", "services", "stargate", "overview"}, cbi("stargate/client/overview"), _("Overview"), 10).leaf = true
  entry({"admin", "services", "stargate", "node"}, cbi("stargate/client/node"), _("Node"), 20).leaf = true
  entry({"admin", "services", "stargate", "dns"}, cbi("stargate/client/dns"), _("DNS"), 30).leaf = true
  entry({"admin", "services", "stargate", "rules"}, cbi("stargate/client/rules"), _("Rules"), 40).leaf = true
  entry({"admin", "services", "stargate", "component"}, cbi("stargate/client/component"), _("Component Settings"), 50).leaf = true
  entry({"admin", "services", "stargate", "safety"}, cbi("stargate/client/safety"), _("Safety"), 60).leaf = true

  local probe = entry({"admin", "services", "stargate", "connect_status"}, call("connect_status"))
  probe.leaf = true
  probe.acl_depends = { "luci-app-stargate" }
end

local function shellquote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function millis(value)
  local number = tonumber(value) or 0
  return math.floor(number * 1000 + 0.5)
end

function connect_status()
  local http = require "luci.http"
  local jsonc = require "luci.jsonc"
  local sys = require "luci.sys"

  local target = http.formvalue("target") or http.formvalue("type")
  local probes = {
    baidu = {
      name = "Baidu",
      url = "https://www.baidu.com/",
      route_ip = "180.101.50.242"
    },
    google = {
      name = "Google",
      url = "https://www.google.com/generate_204",
      route_ip = "142.250.72.14"
    },
    github = {
      name = "GitHub",
      url = "https://github.com/",
      route_ip = "140.82.112.4"
    }
  }

  local probe = probes[target or ""]
  local result = {
    target = target or "",
    ok = false,
    code = 0,
    use_time = 0,
    ping_type = "curl",
    message = "unknown target"
  }

  if probe then
    local route = sys.exec("ip route get " .. shellquote(probe.route_ip) .. " 2>/dev/null | head -1")
    local cmd = table.concat({
      "out=$(curl --noproxy '*' -L -sS -o /dev/null",
      "--connect-timeout 4 --max-time 8",
      "-w 'code=%{http_code} dns=%{time_namelookup} tcp=%{time_connect} tls=%{time_appconnect} total=%{time_total}'",
      shellquote(probe.url),
      "2>&1); rc=$?; printf '%s\\nrc=%s' \"$out\" \"$rc\""
    }, " ")
    local output = sys.exec(cmd)
    local rc = tonumber(output:match("rc=(%d+)")) or 1
    local code = tonumber(output:match("code=(%d+)")) or 0
    local total = output:match("total=([%d%.]+)") or "0"

    result.name = probe.name
    result.url = probe.url
    result.route = route:gsub("%s+$", "")
    result.dev = route:match("%sdev%s+(%S+)") or ""
    result.src = route:match("%ssrc%s+(%S+)") or ""
    result.rc = rc
    result.code = code
    result.dns_time = millis(output:match("dns=([%d%.]+)"))
    result.tcp_time = millis(output:match("tcp=([%d%.]+)"))
    result.tls_time = millis(output:match("tls=([%d%.]+)"))
    result.use_time = millis(total)
    result.ok = (rc == 0 and code >= 200 and code < 500)

    if result.ok then
      result.message = "ok"
    else
      local first_line = output:match("^([^\n\r]+)") or "curl failed"
      result.message = first_line:gsub("^curl:%s*", "")
    end
  end

  http.prepare_content("application/json")
  http.write(jsonc.stringify(result))
end
