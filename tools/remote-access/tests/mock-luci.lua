local function quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

package.preload["luci.jsonc"] = function()
  return {
    parse = function(text)
      local path = os.tmpname()
      local file = assert(io.open(path, "w"))
      file:write(text)
      file:close()
      local filter = 'def lua: if type == "object" then "{" + (to_entries | map("[" + (.key | @json) + "]=" + (.value | lua)) | join(",")) + "}" elif type == "array" then "{" + (map(lua) | join(",")) + "}" elif type == "null" then "nil" else @json end; lua'
      local pipe = assert(io.popen("/host/usr/bin/jq -er " .. quote(filter) .. " " .. quote(path) .. " 2>/dev/null"))
      local expression = pipe:read("*a")
      local ok = pipe:close()
      os.remove(path)
      if not ok then return nil end
      return assert(load("return " .. expression))()
    end
  }
end

package.preload["luci.template.parser"] = function()
  return {
    parse = function(path)
      local file = assert(io.open(path, "r"))
      local template = file:read("*a")
      file:close()
      local blocks = {}
      for source in template:gmatch("<%%(.-)%%>") do
        local marker = source:sub(1, 1)
        if marker == "=" then
          blocks[#blocks + 1] = "do local value = " .. source:sub(2) .. " end"
        elseif marker ~= ":" then
          blocks[#blocks + 1] = source
        end
      end
      local compiled, err = load(table.concat(blocks, "\n"))
      if not compiled then return nil, 1, err end
      return string.dump(compiled)
    end
  }
end

local args = {...}
if args[1] == "-" then
  arg = { [0] = "-" }
  for i = 2, #args do arg[i - 1] = args[i] end
  assert(load(io.read("*a")))()
elseif args[1] == "-e" then
  assert(load(args[2]))()
else
  arg = { [0] = args[1] }
  for i = 2, #args do arg[i - 1] = args[i] end
  assert(loadfile(args[1]))()
end
