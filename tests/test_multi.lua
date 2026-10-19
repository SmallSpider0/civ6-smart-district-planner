-- @state SDP_Panel
-- @timeout 600
-- Multi-city planning with the real DMT (docs/multicity-design.md 4):
-- a city-center pin near the capital, the capital and the new city planned
-- together. Needs a city: run tests/fixtures/found_capital.lua first;
-- game.py newgame --capital --reveal also reveals the land around it.
local test, T = ...

local pid = Game.GetLocalPlayer()

local function Capital()
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then T.skip("no capital: run tests/fixtures/found_capital.lua") end
  return city
end

-- A free land plot 5 plots from the capital for a city-center pin.
local function SitePlot(city)
  local list, centers = SDP_Sites.Candidates(pid, { K = 1, D = 8 })
  for _, c in ipairs(list) do
    if Map.GetPlotDistance(c.X, c.Y, city:GetX(), city:GetY()) == 5 then return c end
  end
  return list[1]
end

local function WithSitePin(fn)
  local city = Capital()
  local site = SitePlot(city)
  if site == nil then T.skip("no site candidate near the capital") end
  local cfg = PlayerConfigurations[pid]
  local pin = cfg:GetMapPin(site.X, site.Y)
  pin:SetIconName("ICON_DISTRICT_CITY_CENTER")
  pin:SetName("SDP test site")
  Network.BroadcastPlayerInfo()
  LuaEvents.DMT_MapPinAdded(pin)
  local pinID = pin:GetID()
  local ok, err = pcall(fn, city, site)
  LuaEvents.DMT_MapPinRemoved(cfg:GetMapPinID(pinID))
  cfg:DeleteMapPin(pinID)
  Network.BroadcastPlayerInfo()
  if not ok then error(err, 0) end
end

local function Types(bases)
  local plannable, out = {}, {}
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do plannable[d.Type] = true end
  for _, base in ipairs(bases) do
    local t = base
    if not plannable[t] then
      for row in GameInfo.DistrictReplaces() do
        if row.ReplacesDistrictType == base and plannable[row.CivUniqueDistrictType] then t = row.CivUniqueDistrictType end
      end
    end
    if plannable[t] then out[#out + 1] = t end
  end
  return out
end

test("the pin is a new city and the capital takes part", function()
  WithSitePin(function(city, site)
    local parts = SDP_Multi.Participants(pid)
    local hasSite, hasCapital = false, false
    for _, p in ipairs(parts) do
      if p.Kind == "SITE" and p.X == site.X and p.Y == site.Y then hasSite = true end
      if p.Kind == "CITY" and p.CityID == city:GetID() then hasCapital = true end
    end
    T.ok(hasSite, "site pin")
    T.ok(hasCapital, "capital within 7 plots")
  end)
end)

test("a plan for both: legal, one subject per plot, not worse than city by city", function()
  WithSitePin(function()
    local districts = Types({ "DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_GOVERNMENT" })
    for _, tier in ipairs({ "FAST", "STANDARD" }) do
      local result = SDP_Multi.Solve({ PlayerID = pid, Tier = tier, Districts = districts })
      T.ok(result.Ok, tier .. ": " .. tostring(result.Error))
      T.ok(not result.Stats.Mismatch, tier .. ": incremental and full evaluation disagree")
      T.ok(result.Gain >= result.FirstGain - 1e-6, tier .. ": worse than city by city")
      local used, plazas = {}, 0
      for _, p in ipairs(result.Plan) do
        T.ok(not used[p.Index], "plot used twice")
        used[p.Index] = true
        if GameInfo.Districts[p.Type] and GameInfo.Districts[p.Type].MaxPerPlayer == 1 then plazas = plazas + 1 end
      end
      T.ok(plazas <= 1, "empire limit")
      print(string.format("%s: gain %.1f (city by city %.1f), %d solutions, %d DMT calls, %d tries", tier, result.Gain,
        result.FirstGain or 0, #result.Solutions, result.Stats.Calls, result.Stats.Tries))
    end
  end)
end)

test("wonders: legal where placed, built ones left out", function()
  WithSitePin(function()
    local wonders = {}
    for _, w in ipairs(SDP_Wonders.List(pid)) do
      if w.Status == nil and #wonders < 3 then wonders[#wonders + 1] = w.Type end
    end
    if #wonders == 0 then T.skip("no free wonder") end
    local result = SDP_Multi.Solve({ PlayerID = pid, Tier = "FAST", Wonders = wonders,
      Districts = Types({ "DISTRICT_CAMPUS", "DISTRICT_THEATER" }) })
    T.ok(result.Ok, tostring(result.Error))
    T.ok(not result.Stats.Mismatch, "legality of the wonders agrees with DMT")
    SDP_Overlay.With(pid, function()
      for _, p in ipairs(result.Plan) do
        if p.Kind == "WONDER" then
          local subjects = {}
          for _, q in ipairs(result.Plan) do subjects[#subjects + 1] = { Key = q.Type, Type = q.Kind, X = q.X, Y = q.Y } end
          local full = SDP_Overlay.Evaluate(subjects, {}, { YIELD_SCIENCE = 1 })
          T.ok(full.Legal, p.Type .. " not legal with the plan")
        end
      end
    end)
  end)
end)
