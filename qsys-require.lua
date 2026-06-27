-- qsys-require.lua
-- Minimal Lua 5.3 loader for Q-SYS scripts.

local function loadModule(path)
  local file = assert(io.open(path, "r"))
  local source = file:read("*a")
  file:close()

  return assert(load(source, "@" .. path))()
end

local Navigator = loadModule("/design/lua/Navigator.lua")
