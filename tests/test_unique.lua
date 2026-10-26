-- @state SDP_Panel
-- @timeout 60
-- @setup GameCore_Tuner tests/fixtures/limited_prepare.lua
-- @setup InGame tests/fixtures/limited_order.lua
-- @setup GameCore_Tuner tests/fixtures/limited_finish.lua
-- @teardown GameCore_Tuner tests/fixtures/limited_destroy.lua
-- A district the empire may have only one of (Districts.MaxPerPlayer, e.g.
-- the Government Plaza), built in the capital the way the player builds it
-- (ordered, then finished: AGENTS pitfall 36). The Several cities tab shows
-- it as built and takes no click; the Single city tab greys it out (issue
-- 108). Skips in the base game, which has no such district.
local test, T = ...

local pid = Game.GetLocalPlayer()

-- The district the fixtures build: the first empire-limited type without a
-- civilization trait, by type name; and its plannable row.
local function Limited()
  local capital = Players[pid]:GetCities():GetCapitalCity()
  if capital == nil then T.skip("no capital") end
  local types = {}
  for row in GameInfo.Districts() do
    if row.MaxPerPlayer ~= nil and row.MaxPerPlayer > 0 and row.TraitType == nil then types[#types + 1] = row.DistrictType end
  end
  table.sort(types)
  if #types == 0 then T.skip("no empire-limited district in this ruleset") end
  for _, d in ipairs(SDP_Rules.PlannableDistricts(pid)) do
    if d.Type == types[1] then return d, capital end
  end
  T.skip(types[1] .. " is not plannable for this civilization")
end

local function Row(rows, districtType)
  for _, r in ipairs(rows) do
    if r.Type == districtType then return r end
  end
end

test("the empire-limited district stands in the capital", function()
  local d = Limited()
  local count = 0
  for _, district in Players[pid]:GetDistricts():Members() do
    if GameInfo.Districts[district:GetType()].DistrictType == d.Type then count = count + 1 end
  end
  T.ok(count >= d.MaxPerPlayer, "the setup built " .. d.Type .. ": " .. count)
  T.eq(SDP_City.EmpireBuilt(pid, SDP_Rules.PlannableDistricts(pid))[d.Type], "BUILT", "EmpireBuilt")
end)

test("several cities tab: shown as built, takes no click, never asked for", function()
  local d = Limited()
  SDP_Panel.SelectTab("MULTI")
  local multi = SDP_Panel.Multi
  multi.SetPlanFor("ALL")
  multi.Refresh()
  local row = Row(multi.State().View.Districts, d.Type)
  T.ok(row ~= nil, "a cell for " .. d.Type)
  T.eq(row.Built, true, "shown as built")
  T.ok(row.Cell:IsDisabled(), "the cell is disabled")
  -- Required before it was built (lists are remembered): still not sent.
  multi.SetState(d.Type, "MUST")
  local request = multi.Request()
  for _, districtType in ipairs(request and request.Districts or {}) do T.ok(districtType ~= d.Type, "not required") end
  for _, districtType in ipairs(request and request.Pool or {}) do T.ok(districtType ~= d.Type, "not a candidate") end
  T.eq(Row(multi.State().View.Districts, d.Type).Built, true, "still built")
  multi.SetState(d.Type, SDP_UI.DefaultState(d))
end)

test("single city tab: greyed out in the capital", function()
  local d, capital = Limited()
  SDP_Panel.SelectTab("SINGLE")
  SDP_Panel.SelectCity(capital:GetID())
  SDP_Panel.Refresh()
  local row = Row(SDP_Panel.State().DistrictRows, d.Type)
  T.ok(row ~= nil, "a cell for " .. d.Type)
  T.ok(row.Status ~= nil, "a status: built here or the empire's limit")
  T.ok(row.Cell:IsDisabled(), "the cell is disabled")
end)
