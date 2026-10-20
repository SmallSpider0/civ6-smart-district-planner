-- cmp_sdp.lua: Smart District Planner (this mod) as a comparison planner.
-- Loads the mod's scripts in the panel's include order, lets the game
-- "finish loading" (Events.LoadGameViewStateDone), and solves at once with
-- weights 1 and, by default, adjacency only (the judge's gain).
--   variant FAST | STANDARD | FINE   the tier
--   variant STANDARD_LAND (any tier + "_LAND")  with the land part on, as the
--                                    panel has it by default
--   variant CITY_BY_CITY             multi only: each city planned alone with
--                                    STANDARD, in city order, earlier plans
--                                    pinned (the baseline a player gets by
--                                    using the single-city tab city by city)

CmpAdapters = CmpAdapters or {}

local function LoadSDP()
  include("MapTacks")
  for _, name in ipairs({ "SDP_Rules", "SDP_City", "SDP_Overlay", "SDP_Tiers", "SDP_Task", "SDP_Board", "SDP_Land",
    "SDP_Search", "SDP_Solver", "SDP_Wonders", "SDP_Multi", "SDP_Sites", "SDP_SiteSolver" }) do
    include(name)
  end
end

-- Put a plan on the map as pins, the way DMT's context records them.
local function Pin(type, x, y)
  local pin = PlayerConfigurations[0]:GetMapPin(x, y)
  pin:SetIconName("ICON_" .. type)
  local subject = CreateMapPinSubject(pin)
  local real = UpdateMapPinSubject
  real(0, x, y, subject)
end

function CmpAdapters.sdp(request, variant, w)
  -- "<TIER>_LAND": the land part on (the panel's default), else adjacency only.
  local land = false
  if variant:match("_LAND$") then
    land = true
    variant = variant:gsub("_LAND$", "")
  end
  LoadSDP()
  w.Events.LoadGameViewStateDone()
  local stats = {}
  CmpRun.CountDMT(stats)
  local scn = request.scenario
  local out = { placements = {}, stats = stats, notes = {} }
  local function Take(plan, cityID)
    for _, p in ipairs(plan or {}) do
      out.placements[#out.placements + 1] = { city = cityID, type = p.Type, x = p.X, y = p.Y }
    end
  end
  if scn.kind == "sites" then
    -- The sites tab: K sites within D, scored with the scenario's districts.
    local r = SDP_SiteSolver.Solve({ PlayerID = 0, Tier = variant, K = request.sites.count, D = request.sites.distance,
      Districts = request.districts })
    if not r.Ok then out.notes[#out.notes + 1] = tostring(r.Error) end
    for _, site in ipairs((r.Ok and r.Solutions[1] and r.Solutions[1].Sites) or {}) do
      out.placements[#out.placements + 1] = { kind = "SITE", x = site.X, y = site.Y }
    end
    stats.method = "sites"
  elseif scn.kind == "single" and #(request.wonders or {}) > 0 then
    -- Wonders with the districts: the single-city tab solves this city as
    -- SDP_Multi with only this city (SDP_Panel's WonderRequest).
    local id = request.target:GetID()
    local r = SDP_Multi.Solve({ PlayerID = 0, Tier = variant, Districts = request.districts, Wonders = request.wonders,
      Only = { [id] = true }, Weights = request.weights, Land = land })
    if not r.Ok then out.notes[#out.notes + 1] = tostring(r.Error) end
    for _, p in ipairs(r.Plan or {}) do
      out.placements[#out.placements + 1] = { city = id, type = p.Type, x = p.X, y = p.Y, kind = p.Kind }
    end
    stats.sdpGain = r.Adjacency
    for _, u in ipairs(r.Unplaced or {}) do out.notes[#out.notes + 1] = "unplaced " .. tostring(u.Type) .. " " .. tostring(u.Reason) end
  elseif scn.kind == "single" then
    local r = SDP_Solver.Solve({ PlayerID = 0, CityID = request.target:GetID(), Districts = request.districts,
      Land = land, Tier = variant, Weights = request.weights })
    if not r.Ok then out.notes[#out.notes + 1] = tostring(r.Error) end
    Take(r.Plan, request.target:GetID())
    stats.sdpGain = r.Adjacency
    stats.method = r.Stats and r.Stats.Method
    for _, u in ipairs(r.Unplaced or {}) do out.notes[#out.notes + 1] = "unplaced " .. u.Type .. " " .. tostring(u.Reason) end
  elseif variant == "CITY_BY_CITY" then
    for _, city in ipairs(request.cities) do
      local r = SDP_Solver.Solve({ PlayerID = 0, CityID = city:GetID(), Districts = request.districts,
        Land = false, Tier = "STANDARD", Weights = request.weights })
      if not r.Ok then out.notes[#out.notes + 1] = tostring(r.Error) end
      Take(r.Plan, city:GetID())
      for _, p in ipairs(r.Plan or {}) do Pin(p.Type, p.X, p.Y) end
      for _, u in ipairs(r.Unplaced or {}) do out.notes[#out.notes + 1] = "unplaced " .. u.Type .. " " .. tostring(u.Reason) end
    end
  else
    local existing = {}
    for _, city in ipairs(request.cities) do existing[city:GetID()] = true end
    local r = SDP_Multi.Solve({ PlayerID = 0, Tier = variant, Districts = request.districts, Existing = existing,
      Land = land, Weights = request.weights })
    if not r.Ok then out.notes[#out.notes + 1] = tostring(r.Error) end
    local byKey = {}
    for _, c in ipairs(r.Cities or {}) do byKey[c.Key] = c.CityID end
    for _, p in ipairs(r.Plan or {}) do
      if p.Kind == nil or p.Kind == "DISTRICT" then
        out.placements[#out.placements + 1] = { city = byKey[p.City], type = p.Type, x = p.X, y = p.Y }
      end
    end
    stats.sdpGain = r.Adjacency
    for _, u in ipairs(r.Unplaced or {}) do out.notes[#out.notes + 1] = "unplaced " .. tostring(u.Type) .. " " .. tostring(u.Reason) end
  end
  return out
end
