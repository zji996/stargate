module("luci.controller.stargate", package.seeall)

local backup_tmp_prefix = "/tmp/stargate-backup-"
local restore_upload = "/tmp/stargate-restore-upload.tar.gz"
local singbox_upload = "/tmp/stargate-sing-box-upload"

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
  entry({"admin", "services", "stargate", "advanced"}, cbi("stargate/client/advanced"), _("Advanced"), 50).leaf = true
  entry({"admin", "services", "stargate", "component"}, cbi("stargate/client/component"), _("Maintenance"), 60).leaf = true
  entry({"admin", "services", "stargate", "logs"}, cbi("stargate/client/logs"), _("Logs"), 70).leaf = true

  local probe = entry({"admin", "services", "stargate", "connect_status"}, call("connect_status"))
  probe.leaf = true
  probe.acl_depends = { "luci-app-stargate" }

  local backup = entry({"admin", "services", "stargate", "backup_download"}, call("backup_download"))
  backup.leaf = true
  backup.acl_depends = { "luci-app-stargate" }

  local restore = entry({"admin", "services", "stargate", "backup_restore"}, call("backup_restore"))
  restore.leaf = true
  restore.acl_depends = { "luci-app-stargate" }

  local singbox = entry({"admin", "services", "stargate", "singbox_upgrade"}, call("singbox_upgrade"))
  singbox.leaf = true
  singbox.acl_depends = { "luci-app-stargate" }

  local rules = entry({"admin", "services", "stargate", "rules_test"}, call("rules_test"))
  rules.leaf = true
  rules.acl_depends = { "luci-app-stargate" }
end

local function shellquote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function millis(value)
  local number = tonumber(value) or 0
  return math.floor(number * 1000 + 0.5)
end

local function trim(value)
  return (value or ""):gsub("%s+$", "")
end

local function uci_get(config, section, option, default)
  local sys = require "luci.sys"
  local value = trim(sys.exec("uci -q get " .. shellquote(config .. "." .. section .. "." .. option) .. " 2>/dev/null"))
  if value == "" then
    return default or ""
  end
  return value
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
      host = "www.baidu.com"
    },
    google = {
      name = "Google",
      url = "https://www.google.com/generate_204",
      host = "www.google.com"
    },
    github = {
      name = "GitHub",
      url = "https://github.com/",
      host = "github.com"
    }
  }

  local probe = probes[target or ""]
  local result = {
    target = target or "",
    ok = false,
    code = 0,
    use_time = 0,
    ping_type = "curl",
    mode = "unknown",
    mode_label = "Unknown",
    message = "unknown target"
  }

  if probe then
    local transparent = uci_get("stargate", "inbound", "transparent_proxy", "0") == "1"
    local service_state = trim(sys.exec("/etc/init.d/stargate status 2>/dev/null"))
    local firewall_status = sys.exec("/usr/share/stargate/stargate.sh firewall-status 2>/dev/null")
    local firewall_active = firewall_status:match("Active:%s*yes") ~= nil
    local proxy_mode = "local"
    local proxy_arg = ""
    local proxy_label = "Stargate local proxy path"

    result.name = probe.name
    result.url = probe.url
    result.service = service_state
    result.firewall_active = firewall_active

    if service_state ~= "running" then
      result.mode = "stopped"
      result.mode_label = "Stargate is not running"
      result.message = "stargate service is not running"
      http.prepare_content("application/json")
      http.write(jsonc.stringify(result))
      return
    end

    local http_listen = uci_get("stargate", "inbound", "http_listen", "127.0.0.1")
    local http_port = uci_get("stargate", "inbound", "http_port", "10809")
    if http_listen == "0.0.0.0" or http_listen == "::" or http_listen == "" then
      http_listen = "127.0.0.1"
    end
    proxy_arg = "--proxy " .. shellquote("http://" .. http_listen .. ":" .. http_port)

    if transparent and firewall_active then
      proxy_mode = "transparent"
      proxy_label = "Stargate transparent path"
    elseif transparent then
      proxy_label = "Stargate local proxy path (forwarding inactive)"
    end

    local route_target = sys.exec("resolveip -4 " .. shellquote(probe.host) .. " 2>/dev/null | head -1")
    route_target = trim(route_target)
    if route_target == "" then
      route_target = probe.host
    end
    local route = sys.exec("ip route get " .. shellquote(route_target) .. " 2>/dev/null | head -1")
    local cmd = table.concat({
      "out=$(curl -L -sS -o /dev/null",
      proxy_arg ~= "" and proxy_arg or "--noproxy '*'",
      "--connect-timeout 4 --max-time 8",
      "-w 'code=%{http_code} dns=%{time_namelookup} tcp=%{time_connect} tls=%{time_appconnect} total=%{time_total}'",
      shellquote(probe.url),
      "2>&1); rc=$?; printf '%s\\nrc=%s' \"$out\" \"$rc\""
    }, " ")
    local output = sys.exec(cmd)
    local rc = tonumber(output:match("rc=(%d+)")) or 1
    local code = tonumber(output:match("code=(%d+)")) or 0
    local total = output:match("total=([%d%.]+)") or "0"

    result.mode = proxy_mode
    result.mode_label = proxy_label
    result.proxy = proxy_arg ~= ""
    result.route = trim(route)
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

function rules_test()
  local http = require "luci.http"
  local jsonc = require "luci.jsonc"
  local sys = require "luci.sys"
  local util = require "luci.util"

  local target = http.formvalue("target") or ""
  local cmd = "/usr/share/stargate/stargate.sh rules-test " .. shellquote(target) .. " 2>&1; printf '\\n__rc=%s' $?"
  local output = sys.exec(cmd)
  local rc = tonumber(output:match("__rc=(%d+)%s*$")) or 1
  output = output:gsub("\n?__rc=%d+%s*$", "")

  http.prepare_content("application/json")
  http.write(jsonc.stringify({
    ok = (rc == 0),
    output = util.trim(output)
  }))
end

function backup_download()
  local http = require "luci.http"
  local fs = require "nixio.fs"
  local sys = require "luci.sys"

  local file = backup_tmp_prefix .. os.date("%Y%m%d-%H%M%S") .. ".tar.gz"
  local output = sys.exec("/usr/share/stargate/stargate.sh backup-create " .. shellquote(file) .. " 2>&1")
  if not fs.access(file) then
    http.status(500, "Backup failed")
    http.prepare_content("text/plain")
    http.write(output)
    return
  end

  http.header("Content-Disposition", "attachment; filename=\"" .. file:match("([^/]+)$") .. "\"")
  http.prepare_content("application/gzip")
  local fp = io.open(file, "rb")
  if fp then
    while true do
      local chunk = fp:read(4096)
      if not chunk then
        break
      end
      http.write(chunk)
    end
    fp:close()
  end
  fs.unlink(file)
end

function backup_restore()
  local http = require "luci.http"
  local sys = require "luci.sys"
  local util = require "luci.util"
  local jsonc = require "luci.jsonc"

  local upload = restore_upload
  local fp

  http.setfilehandler(function(meta, chunk, eof)
    if meta and meta.name == "archive" then
      if not fp then
        fp = io.open(upload, "wb")
      end
      if chunk and fp then
        fp:write(chunk)
      end
      if eof and fp then
        fp:close()
        fp = nil
      end
    end
  end)

  local output = ""
  local ok = false
  if http.formvalue("restore") then
    output = sys.exec("/usr/share/stargate/stargate.sh backup-restore " .. shellquote(upload) .. " 2>&1")
    ok = not output:match("[Ee]rror") and not output:match("[Ff]ailed") and not output:match("invalid") and not output:match("missing")
  else
    output = "missing restore request"
  end
  os.remove(upload)

  http.prepare_content("application/json")
  http.write(jsonc.stringify({ ok = ok, output = util.trim(output) }))
end

function singbox_upgrade()
  local http = require "luci.http"
  local sys = require "luci.sys"
  local util = require "luci.util"
  local jsonc = require "luci.jsonc"

  local upload = singbox_upload
  local fp

  http.setfilehandler(function(meta, chunk, eof)
    if meta and meta.name == "binary" then
      if not fp then
        fp = io.open(upload, "wb")
      end
      if chunk and fp then
        fp:write(chunk)
      end
      if eof and fp then
        fp:close()
        fp = nil
      end
    end
  end)

  local output = ""
  local ok = false
  if http.formvalue("upgrade") then
    output = sys.exec("/usr/share/stargate/stargate.sh singbox-upgrade " .. shellquote(upload) .. " 2>&1")
    ok = not output:match("[Ee]rror") and not output:match("[Ff]ailed") and not output:match("missing") and not output:match("not a runnable")
  else
    output = "missing upgrade request"
  end
  os.remove(upload)

  http.prepare_content("application/json")
  http.write(jsonc.stringify({ ok = ok, output = util.trim(output) }))
end
