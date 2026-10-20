-- Offline: SDP_Overlay builds DMT's modifier cache in this state.
-- SDP_Overlay removes the load handlers DMT_Initialize subscribed here, and
-- those handlers are what built DMT's cache of the player's trait and belief
-- modifiers (civilization adjacency and placement rules). Without the cache
-- DMT in the panel's state ignores Japan's district adjacency, Gaul's rule
-- against specialty districts next to the city center, and so on.
local test, T = ...

-- Stand-ins for DMT's two functions, counting calls. Installed before the
-- include, as DMT defines them before SDP_Overlay runs.
local calls = { init = 0, cache = 0, player = nil }
sdp_install_globals({
  InitializeModifierCalculator = function() calls.init = calls.init + 1 end,
  CacheEffectiveModifiers = function(playerID)
    calls.cache = calls.cache + 1
    calls.player = playerID
  end,
})

include("SDP_Rules")
include("SDP_City")
include("SDP_Overlay")

test("the game's load event builds the modifier cache once", function()
  T.eq(calls.init, 0, "nothing before the game has loaded")
  Events.LoadGameViewStateDone()
  T.eq(calls.init, 1)
  T.eq(calls.cache, 1)
  T.eq(calls.player, 0, "for the local player")
end)

test("every turn start refreshes the player's modifiers, the requirement tables stay", function()
  local cache = calls.cache
  Events.LocalPlayerTurnBegin()
  Events.LocalPlayerTurnBegin()
  T.eq(calls.cache, cache + 2)
  T.eq(calls.init, 1, "InitializeModifierCalculator appends to its tables: once only")
end)

test("DMT's own load handlers stay removed", function()
  -- world.lua's DMT stand-ins are no-ops; the real ones would rebuild DMT's
  -- pin subjects and broadcast them from this state.
  for _, name in ipairs({ "OnLoadGameViewStateDone", "OnLocalPlayerTurnBegin" }) do
    T.ok(sdp_global(name) ~= nil, name .. " exists")
  end
  local before = calls.cache
  Events.LoadGameViewStateDone()
  T.eq(calls.cache, before + 1, "only SDP_Overlay's handler runs")
end)
