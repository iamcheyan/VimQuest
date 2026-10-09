-- Compatibility entry for installations that used VimQuest as a Lua directory.
local root = debug.getinfo(1, "S").source:sub(2):match("^(.*)/init.lua$")
return dofile(root .. "/lua/vimquest/init.lua")
