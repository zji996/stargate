local sys = require "luci.sys"
local util = require "luci.util"

local M = {}

function M.prepare_map(map)
  local section = map:section(require("luci.cbi").SimpleSection)
  section.template = "stargate/common"
end

function M.action(name)
  local http = require "luci.http"
  local dispatcher = require "luci.dispatcher"
  if http.getenv("REQUEST_METHOD") ~= "POST" then return nil end
  local token = dispatcher.context.authtoken
  if type(token) ~= "string" or token == "" or http.formvalue("token") ~= token then return nil end
  return http.formvalue(name)
end

function M.trim(value)
  return (value or ""):gsub("%s+$", "")
end

function M.ui_text(en, zh)
  local lang = M.trim(sys.exec("uci -q get luci.main.lang 2>/dev/null || echo auto"))
  if lang == "zh_cn" or lang == "zh-cn" or lang == "zh" or lang == "auto" then
    return zh
  end
  return en
end

function M.pc(value)
  return util.pcdata(value or "")
end

function M.shellquote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

function M.status_rows(output)
  local rows = {}
  for line in (output or ""):gmatch("[^\r\n]+") do
    local key, value = line:match("^([^:]+):%s*(.*)$")
    if key and value then
      rows[#rows + 1] = { key, value }
    end
  end
  return rows
end

function M.status_rows_html(rows, class_name)
  local parts = {}
  for _, row in ipairs(rows or {}) do
    parts[#parts + 1] = '<div class="' .. class_name .. '"><span>' .. M.pc(row[1]) .. '</span><strong>' .. M.pc(row[2]) .. '</strong></div>'
  end
  return table.concat(parts, "\n")
end

function M.depends_any(option, field, values)
  for _, value in ipairs(values) do
    option:depends(field, value)
  end
end

return M
