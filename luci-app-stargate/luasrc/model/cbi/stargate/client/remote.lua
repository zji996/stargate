local sys = require "luci.sys"
local http = require "luci.http"
local fs = require "nixio.fs"
local nixio = require "nixio"
local json = require "luci.jsonc"
local ip = require "luci.ip"
local common = require "luci.model.stargate.common"

local binary = "/usr/bin/stargate-remote"
local bridge = "/usr/share/stargate/remote-control.sh"
local directory = "/etc/stargate-remote"
local quote = common.shellquote

local function identifier(value)
  return type(value) == "string" and #value <= 48 and value:match("^[a-z][a-z0-9_%-]*$") ~= nil
end

local function service_key(value)
  if type(value) ~= "string" then return false end
  local provider, id = value:match("^([^/]+)/([^/]+)$")
  return identifier(provider) and identifier(id)
end

local function port(value, minimum)
  local text = tostring(value or "")
  local number = tonumber(text)
  return text:match("^[1-9][0-9]*$") and number and number >= minimum and number <= 65535
end

local networks = {
  ip.new("10.0.0.0/8"), ip.new("172.16.0.0/12"), ip.new("192.168.0.0/16"),
  ip.new("127.0.0.0/8"), ip.new("fc00::/7"), ip.new("::1/128")
}

local function local_address(value)
  if type(value) ~= "string" or #value > 45 or value:find("/", 1, true) then return false end
  local ok, address = pcall(ip.new, value)
  if not ok or not address then return false end
  for _, network in ipairs(networks) do
    if network:contains(address) then return true end
  end
  return false
end

local function array(value, check, maximum)
  if type(value) ~= "table" then return false end
  local count = 0
  for key, entry in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or not check(entry) then return false end
    count = count + 1
  end
  return count == #value and count <= (maximum or 4096)
end

local function string_array(value)
  return array(value, identifier)
end

local function service(value)
  return type(value) == "table" and identifier(value.id) and identifier(value.provider)
    and local_address(value.local_ip) and port(value.local_port, 1)
    and type(value.enabled) == "boolean" and string_array(value.visitors)
end

local function clean_service(value)
  return { id = value.id, provider = value.provider, local_ip = value.local_ip,
    local_port = value.local_port, enabled = value.enabled, visitors = value.visitors }
end

local function read_status()
  if not fs.access(binary, "x") then return { state = "missing" } end
  local fallback = fs.access(directory .. "/profile.json") and "unavailable" or "unenrolled"
  local output = sys.exec(quote(binary) .. " status --dir " .. quote(directory) .. " 2>/dev/null")
  if #output > 1024 * 1024 then return { state = fallback } end
  local ok, raw = pcall(json.parse, output)
  if not ok or type(raw) ~= "table" or raw.schema ~= 1 or not identifier(raw.device_id)
    or (raw.role ~= "provider" and raw.role ~= "visitor" and raw.role ~= "both" and raw.role ~= "none")
    or type(raw.revision) ~= "number" or raw.revision < 0 or raw.revision % 1 ~= 0
    or not string_array(raw.visitor_ids or {}) then return { state = fallback } end
  local clean = { state = "ready", device_id = raw.device_id, role = raw.role, revision = raw.revision,
    visitor_ids = raw.visitor_ids or {}, services = {}, available_services = {}, bindings = {}, grants = {},
    publish = raw.role == "provider" or raw.role == "both", bind = raw.role == "visitor" or raw.role == "both" }
  if raw.capabilities ~= nil then
    if type(raw.capabilities) ~= "table" or type(raw.capabilities.publish) ~= "boolean"
      or type(raw.capabilities.bind) ~= "boolean" then return { state = fallback } end
    clean.publish, clean.bind = raw.capabilities.publish, raw.capabilities.bind
  end
  if raw.transport ~= nil then
    local t = raw.transport
    if type(t) ~= "table" or not identifier(t.id) or type(t.name) ~= "string" or #t.name > 256
      or type(t.server) ~= "string" or #t.server > 253 or not t.server:match("^[A-Za-z0-9%.:%-]+$")
      or not port(t.port, 1) or type(t.server_name or "") ~= "string" or #(t.server_name or "") > 253 then return { state = fallback } end
    clean.transport = { id = t.id, name = t.name, server = t.server, port = t.port, server_name = t.server_name or "" }
  end
  if raw.format == 2 and raw.services ~= nil then
    if not array(raw.services, service) or not array(raw.available_services or {}, service)
      or not array(raw.grants or {}, function(g)
        return type(g) == "table" and service_key(g.service) and identifier(g.visitor)
      end) or not array(raw.bindings or {}, function(b)
        return type(b) == "table" and identifier(b.id) and identifier(b.device_id) and service_key(b.service)
          and (b.bind_addr == "127.0.0.1" or b.bind_addr == "::1") and port(b.bind_port, 1024) and type(b.enabled) == "boolean"
      end) then return { state = fallback } end
    for _, s in ipairs(raw.services) do clean.services[#clean.services + 1] = clean_service(s) end
    for _, s in ipairs(raw.available_services or {}) do clean.available_services[#clean.available_services + 1] = clean_service(s) end
    for _, g in ipairs(raw.grants or {}) do clean.grants[#clean.grants + 1] = {service = g.service, visitor = g.visitor} end
    for _, b in ipairs(raw.bindings or {}) do clean.bindings[#clean.bindings + 1] = {
      id = b.id, device_id = b.device_id, service = b.service, bind_addr = b.bind_addr, bind_port = b.bind_port, enabled = b.enabled }
    end
  else
    clean.legacy = true
    if not array(raw.mappings or {}, function(m)
      return type(m) == "table" and identifier(m.id) and identifier(m.provider)
        and local_address(m.local_ip) and port(m.local_port, 1) and port(m.bind_port, 1024) and string_array(m.visitors)
    end) then return { state = fallback } end
    for _, m in ipairs(raw.mappings or {}) do
      local s = clean_service({id=m.id, provider=m.provider, local_ip=m.local_ip, local_port=m.local_port, enabled=true, visitors=m.visitors})
      if m.provider == clean.device_id then clean.services[#clean.services + 1] = s end
      if clean.bind then
        clean.available_services[#clean.available_services + 1] = s
        clean.bindings[#clean.bindings + 1] = {id=m.id, device_id=clean.device_id, service=m.provider .. "/" .. m.id,
          bind_addr="127.0.0.1", bind_port=m.bind_port, enabled=true}
      end
    end
  end
  clean.runtime = "staged"
  if type(raw.runtime) == "table" then
    local states = {staged=true, configured=true, applied=true, error=true}
    if states[raw.runtime.state] then clean.runtime = raw.runtime.state end
    if type(raw.runtime.admin_authenticated) == "boolean" then clean.admin_authenticated = raw.runtime.admin_authenticated end
    clean.published = {}
    if array(raw.runtime.published or {}, function(p)
      return type(p) == "table" and identifier(p.id) and (p.status == "running" or p.status == "pending")
    end) then
      for _, p in ipairs(raw.runtime.published or {}) do clean.published[p.id] = p.status end
    end
  end
  local running = sys.exec("/etc/init.d/stargate-remote status 2>/dev/null"):match("^%s*(%a+)%s*$")
  clean.service_state = running == "running" and "running" or (running == "stopped" and "stopped" or "unknown")
  return clean
end

local function field(name)
  local value = http.formvalue(name)
  return type(value) == "string" and value or ""
end

local function visitors(status)
  local values = http.formvalue("remote_visitors") or {}
  if type(values) == "string" then values = {values} end
  if not string_array(values) then return nil end
  local allowed, seen = {}, {}
  for _, id in ipairs(status.visitor_ids) do allowed[id] = true end
  for _, id in ipairs(values) do
    if not allowed[id] or seen[id] then return nil end
    seen[id] = true
  end
  return table.concat(values, ",")
end

local function find(list, id)
  for _, item in ipairs(list or {}) do if item.id == id then return item end end
end

local function enroll()
  local link = field("remote_link")
  if #link > 131072 or not link:match("^stargate://enroll/[A-Za-z0-9_%-]+$") or not fs.access(bridge, "x") then return false end
  local temporary = common.trim(sys.exec("umask 077; mktemp -d /tmp/stargate-remote-enroll-XXXXXX"))
  if not temporary:match("^/tmp/stargate%-remote%-enroll%-%w+$") then return false end
  local path = temporary .. "/link"
  local ok, result = pcall(function()
    local handle = nixio.open(path, "w", 384)
    if not handle then return false end
    local wrote = handle:writeall(link)
    handle:close()
    if not wrote then return false end
    return sys.call(quote(bridge) .. " enroll --link-file " .. quote(path)
      .. " --activate " .. (field("remote_activate") == "1" and "1" or "0")
      .. " --import-proxy " .. (field("remote_import_proxy") == "1" and "1" or "0") .. " >/dev/null 2>&1") == 0
  end)
  fs.unlink(path)
  fs.rmdir(temporary)
  return ok and result
end

local status = read_status()
local action = common.action("stargate_remote_action")
local message
if action then
  local arguments, bridge_action, completed
  if type(action) ~= "string" then
    message = translate("Invalid remote access parameters.")
  elseif fs.access("/var/lock/stargate-remote-install") then
    message = translate("Remote access update failed. Check the service status.")
  elseif action == "enroll" then
    if status.state == "unenrolled" then completed = enroll() end
  elseif status.state ~= "ready" then
    message = translate("Remote access is not ready.")
  elseif action == "start" or action == "stop" then
    if fs.access(bridge, "x") then bridge_action = action end
  elseif action == "sync" then
    arguments = "sync"
  elseif not status.legacy then
    local id, enabled = field("remote_id"), field("remote_enabled")
    local existing = find(status.services, id)
    if action:match("^service%-") and status.publish then
      if action == "service-delete" and existing and existing.provider == status.device_id then
        arguments = "service-delete --id " .. quote(id)
      elseif action == "service-toggle" and existing and existing.provider == status.device_id and (enabled == "true" or enabled == "false") then
        arguments = "service-publish --id " .. quote(id) .. " --target-ip " .. quote(existing.local_ip)
          .. " --target-port " .. quote(existing.local_port) .. " --visitors " .. quote(table.concat(existing.visitors, ",")) .. " --enabled=" .. enabled
      elseif action == "service-save" then
        local allowed = visitors(status)
        if identifier(id) and local_address(field("remote_ip")) and port(field("remote_target_port"), 1)
          and allowed and (enabled == "true" or enabled == "false") then
          arguments = "service-publish --id " .. quote(id) .. " --target-ip " .. quote(field("remote_ip"))
            .. " --target-port " .. quote(field("remote_target_port")) .. " --visitors " .. quote(allowed) .. " --enabled=" .. enabled
        end
      end
    elseif action == "grant-save" and status.publish then
      local key, allowed = field("remote_service"), visitors(status)
      if allowed and service_key(key) then
        for _, s in ipairs(status.services) do
          if s.provider == status.device_id and key == s.provider .. "/" .. s.id then arguments = "grant-set --service " .. quote(key) .. " --visitors " .. quote(allowed) end
        end
      end
    elseif action:match("^binding%-") and status.bind then
      local binding = find(status.bindings, id)
      if action == "binding-delete" and binding and binding.device_id == status.device_id then
        arguments = "binding-delete --id " .. quote(id)
      elseif action == "binding-toggle" and binding and binding.device_id == status.device_id and (enabled == "true" or enabled == "false") then
        arguments = "binding-add --id " .. quote(id) .. " --service " .. quote(binding.service)
          .. " --bind-address " .. quote(binding.bind_addr) .. " --bind-port " .. quote(binding.bind_port) .. " --enabled=" .. enabled
      elseif action == "binding-save" then
        local key, address = field("remote_service"), field("remote_bind_address")
        local permitted = false
        for _, s in ipairs(status.available_services) do if key == s.provider .. "/" .. s.id then permitted = true end end
        if identifier(id) and permitted and (address == "127.0.0.1" or address == "::1")
          and port(field("remote_bind_port"), 1024) and (enabled == "true" or enabled == "false") then
          arguments = "binding-add --id " .. quote(id) .. " --service " .. quote(key)
            .. " --bind-address " .. quote(address) .. " --bind-port " .. quote(field("remote_bind_port")) .. " --enabled=" .. enabled
        end
      end
    end
  end
  if arguments then completed = sys.call(quote(binary) .. " " .. arguments .. " --dir " .. quote(directory) .. " >/dev/null 2>&1") == 0 end
  if bridge_action then completed = sys.call(quote(bridge) .. " " .. bridge_action .. " >/dev/null 2>&1") == 0 end
  if completed ~= nil then
    message = completed and translate("Remote access configuration updated.") or translate("Remote access update failed. Check the service status.")
    status = read_status()
  elseif not message then message = translate("Invalid remote access parameters.") end
end

local form = SimpleForm("stargate_remote", translate("Remote access"))
form.submit = false
form.reset = false
local section = form:section(SimpleSection)
section.template = "stargate/remote"
section.remote_status = status
section.remote_message = message
return form
