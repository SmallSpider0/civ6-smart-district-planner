-- @state InGame
-- Facts about the game's Lua runtime that tools/luacheck.mjs relies on. If a
-- game update breaks one of these, update the checker's rules to match.
local test, T = ...

local function global(name)
  return loadstring("return " .. name)()
end

test("globals the checker bans are nil", function()
  local names = { "_G", "_ENV", "load", "require", "dofile", "module", "setfenv",
                  "getfenv", "debug", "utf8", "bit", "bit32" }
  for _, name in ipairs(names) do
    T.eq(type(global(name)), "nil", name)
  end
  T.eq(type(table.unpack), "nil", "table.unpack") -- lint: allow banned-call
  T.eq(type(table.getn), "nil", "table.getn") -- lint: allow banned-call
end)

test("Lua 5.1 functions the mod uses exist", function()
  for _, name in ipairs({ "loadstring", "unpack", "include", "pcall", "os.clock", "string.format" }) do
    T.eq(type(global(name)), "function", name)
  end
end)

test("a game is running", function()
  T.ok(Game.GetCurrentGameTurn() >= 1, "turn")
  local pid = Game.GetLocalPlayer()
  T.ok(pid >= 0 and Players[pid] ~= nil, "local player")
  T.ok(GameInfo.Districts["DISTRICT_CAMPUS"] ~= nil, "GameInfo.Districts")
end)
