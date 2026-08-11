-- Grow a Garden 2 - Mail Manager
-- Stable entry point. The implementation lives in GAG2_Mail_Manager_v2.luau.

local URL = "https://raw.githubusercontent.com/Smile-B14/GAG2-Mail-Manager/main/GAG2_Mail_Manager_v2.luau"
local source = game:HttpGet(URL, true)
local chunk, compileError = loadstring(source)
assert(chunk, compileError)
return chunk()
