-- @state dmt_yieldcalculator
-- The DMT entry points the planner reuses (AGENTS.md section 4), called in
-- DMT's own Lua state.
local test, T = ...

local function campus(x, y)
  return { Key = "DISTRICT_CAMPUS", Type = "DISTRICT", X = x, Y = y }
end

-- Plots next to the capital, or next to the first unit before the capital is
-- founded (UI states have no Player:GetStartingPlot), in GetAdjacentPlots order.
local function plotsNearStart()
  local player = Players[Game.GetLocalPlayer()]
  local anchor = player:GetCities():GetCapitalCity()
  if anchor == nil then
    for _, unit in player:GetUnits():Members() do
      anchor = unit
      break
    end
  end
  T.ok(anchor ~= nil, "no capital and no units")
  local plots = {}
  for _, plot in ipairs(Map.GetAdjacentPlots(anchor:GetX(), anchor:GetY())) do
    if plot ~= nil then plots[#plots + 1] = plot end
  end
  return plots
end

test("DMT API is present", function()
  for _, name in ipairs({ "CanPlacePin", "GetBonusYields", "GetMapPinSubject",
                          "UpdatePinYields", "UpdateMapPinSubject" }) do
    T.eq(type(loadstring("return " .. name)()), "function", name)
  end
end)

test("CanPlacePin and GetBonusYields answer for a campus", function()
  local pid = Game.GetLocalPlayer()
  for _, plot in ipairs(plotsNearStart()) do
    local subject = campus(plot:GetX(), plot:GetY())
    local canPlace, reason = CanPlacePin(pid, subject)
    T.eq(type(canPlace), "boolean", "CanPlacePin result")
    T.eq(type(reason), "string", "CanPlacePin reason")
    local yields, tooltip = GetBonusYields(pid, subject)
    T.eq(type(yields), "table", "GetBonusYields yields")
    T.eq(type(tooltip), "string", "GetBonusYields tooltip")
    print(string.format("(%d,%d) canPlace=%s science=%s", subject.X, subject.Y,
      tostring(canPlace), tostring(yields.YIELD_SCIENCE or 0)))
  end
end)

test("GetBonusYields is repeatable", function()
  local pid = Game.GetLocalPlayer()
  for _, plot in ipairs(plotsNearStart()) do
    local subject = campus(plot:GetX(), plot:GetY())
    local first, firstTip = GetBonusYields(pid, subject)
    local second, secondTip = GetBonusYields(pid, subject)
    for _, yieldType in ipairs({ "YIELD_SCIENCE", "YIELD_CULTURE", "YIELD_FAITH", "YIELD_GOLD", "YIELD_PRODUCTION" }) do
      T.eq(second[yieldType], first[yieldType], yieldType)
    end
    T.eq(secondTip, firstTip, "tooltip")
  end
end)
