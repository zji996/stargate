local sys = require "luci.sys"
local util = require "luci.util"

local M = {}

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
