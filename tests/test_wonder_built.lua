-- @state SDP_Panel
-- @setup GameCore_Tuner tests/fixtures/wonder_elsewhere.lua
-- @teardown GameCore_Tuner tests/fixtures/wonder_elsewhere_teardown.lua
-- Issue 294: a world wonder another civ completed, seen or not, is not
-- planned; a wonder nobody built is planned even before its technology.
-- Also prints what the build menu's check (BuildQueue:CanProduce) says, for
-- the record on the issue.
local test, T = ...

local pid = Game.GetLocalPlayer()

local function Status(buildingType)
  for _, w in ipairs(SDP_Wonders.List(pid)) do
    if w.Type == buildingType then return w.Status or "free" end
  end
  return nil
end

local function Menu(row)
  local city = Players[pid]:GetCities():GetCapitalCity()
  if city == nil then return "no capital" end
  local queue = city:GetBuildQueue()
  local listed = queue:CanProduce(row.Hash, true)
  local startable, results = queue:CanProduce(row.Hash, false, true)
  local reasons = {}
  for key, value in pairs(results or {}) do reasons[#reasons + 1] = tostring(key) .. "=" .. tostring(value) end
  table.sort(reasons)
  return "CanProduce listed " .. tostring(listed) .. ", startable " .. tostring(startable) .. ", results " .. table.concat(reasons, "; ")
end

test("a world wonder another civ completed is not planned", function()
  local plot = nil
  for index = 0, Map.GetPlotCount() - 1 do
    local p = Map.GetPlotByIndex(index)
    local owner = p:GetOwner()
    if plot == nil and p:GetWonderType() ~= -1 and p:IsWonderComplete() and owner ~= -1 and owner ~= pid then plot = p end
  end
  if plot == nil then error("setup built no wonder for another civ") end
  local row = GameInfo.Buildings[plot:GetWonderType()]
  print(row.BuildingType .. " revealed " .. tostring(PlayersVisibility[pid]:IsRevealed(plot:GetIndex())) .. "; " .. Menu(row))
  T.eq(row.MaxWorldInstances, 1, "a world wonder")
  T.eq(Status(row.BuildingType), "BUILT", row.BuildingType)
end)

test("a wonder nobody built is planned before its technology", function()
  local techs = Players[pid]:GetTechs()
  local built = {}
  for index = 0, Map.GetPlotCount() - 1 do
    local p = Map.GetPlotByIndex(index)
    if p:GetWonderType() ~= -1 then built[p:GetWonderType()] = true end
  end
  local chosen = nil
  for _, w in ipairs(SDP_Wonders.List(pid)) do
    local row = GameInfo.Buildings[w.Type]
    if chosen == nil and row.PrereqTech ~= nil and not built[row.Index]
        and not techs:HasTech(GameInfo.Technologies[row.PrereqTech].Index) then
      chosen = row
    end
  end
  if chosen == nil then T.skip("every wonder's technology is known") end
  print(chosen.BuildingType .. " without " .. chosen.PrereqTech .. "; " .. Menu(chosen))
  T.eq(Status(chosen.BuildingType), "free", chosen.BuildingType)
end)
