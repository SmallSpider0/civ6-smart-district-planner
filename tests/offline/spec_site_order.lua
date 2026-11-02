-- Offline: the order of a solution's city sites (issue 186). The sites tab
-- lists the sites (and numbers their tacks) in the order to settle them:
-- each time the site worth most among those that link back to the player's
-- cities or city-center tacks within the farthest distance, directly or
-- through sites listed before it. A site that is that far only through
-- another site comes after it, even when it is worth more. Driven through
-- the panel's own controls.
local test, T = ...

local UI_Mock = include("ui")

local c = nil

-- The first world installs the panel; a later one replaces the panel's.
local function Setup(spec)
  local ui = UI
  World.New(spec)
  if c ~= nil then
    for key, fn in pairs(ui) do -- the mock's UI functions on the new world's UI
      if UI[key] == nil then UI[key] = fn end
    end
  else
    UI_Mock.Install()
    include("SDP_Panel")
    c = UI_Mock.Controls
  end
end

-- Set the tab's count and distance with its arrow buttons.
local function Set(sites, k, d)
  for _ = 1, 20 do
    local state = sites.State()
    if state.K == k then break end
    if state.K > k then c.SitesCountLess:Click() else c.SitesCountMore:Click() end
  end
  for _ = 1, 20 do
    local state = sites.State()
    if state.D == d then break end
    if state.D > d then c.SitesDistanceLess:Click() else c.SitesDistanceMore:Click() end
  end
  T.eq(sites.State().K, k, "count")
  T.eq(sites.State().D, d, "distance")
end

local function Solve(sites)
  c.SitesSolveButton:Click()
  SDP_Panel.RunTask(2000)
  local result = sites.State().Result
  T.ok(result and result.Ok, "sites result: " .. tostring(result and result.Error))
  return result
end

-- The player's cities and city-center tacks.
local function Anchors()
  local list = {}
  for _, center in ipairs(SDP_Sites.Centers(0)) do
    if center.Own then list[#list + 1] = center end
  end
  return list
end

-- Every solution: each site links back through the ones before it, and no
-- site after it that linked back as early is worth more. Returns how many
-- solutions list their sites other than by plot index.
local function CheckOrder(result, d, anchors)
  local reordered = 0
  for n, solution in ipairs(result.Solutions) do
    local relays = {}
    for _, a in ipairs(anchors) do relays[#relays + 1] = a end
    local function Linked(site)
      for _, r in ipairs(relays) do
        if Map.GetPlotDistance(site.X, site.Y, r.X, r.Y) <= d then return true end
      end
      return false
    end
    local sum = 0
    for i, site in ipairs(solution.Sites) do
      local where = "solution " .. n .. " site " .. i .. " at " .. site.X .. "," .. site.Y
      T.ok(Linked(site), where .. ": links back through the sites before it")
      for j = i + 1, #solution.Sites do
        local later = solution.Sites[j]
        if Linked(later) then
          T.ok(later.Value <= site.Value + 1e-6, where .. " (" .. site.Value .. ") before " .. later.X .. "," .. later.Y
            .. " (" .. later.Value .. ")")
        end
      end
      relays[#relays + 1] = site
      sum = sum + site.Value
      if i > 1 and site.Index < solution.Sites[i - 1].Index then reordered = reordered + 1 end
    end
    T.ok(math.abs(sum - solution.Value - (solution.Conflict or 0)) < 1e-6,
      "solution " .. n .. ": the sites' values add up to the solution's")
  end
  return reordered
end

-- The rows and the tacks follow the sites' order: row s is site s, numbered
-- after the cities in turn, and its tack is named with that number.
local function CheckRowsAndTacks(sites, result, cities)
  local solution = result.Solutions[sites.State().Solution]
  local rows = sites.State().View.Results
  T.eq(#rows, #solution.Sites, "a row per site")
  for s, site in ipairs(solution.Sites) do
    T.eq(rows[s].X .. "," .. rows[s].Y, site.X .. "," .. site.Y, "row " .. s)
    local number = cities + s
    T.ok(rows[s].Name:find("LOC_SDP_SITE_N(" .. number .. ")", 1, true) == 1, "row " .. s .. " named " .. rows[s].Name)
  end
  c.SitesPlaceButton:Click()
  local names = {}
  for _, pin in pairs(PlayerConfigurations[0]:GetMapPins()) do
    names[pin:GetHexX() .. "," .. pin:GetHexY()] = pin:GetName()
  end
  for s, site in ipairs(solution.Sites) do
    T.eq(names[site.X .. "," .. site.Y], tostring(cities + s), "tack of site " .. s)
  end
end

test("sites are listed best first, each linking back through the ones before it", function()
  local spec = World.RandomSpec(7, 24, 16)
  local function Land(x, y)
    local row = spec.rows[y + 1]
    spec.rows[y + 1] = row:sub(1, x) .. "." .. row:sub(x + 2)
  end
  Land(4, 8)
  spec.cities = { { id = 1, x = 4, y = 8, population = 6, capital = true, radius = 1 } }
  Setup(spec)
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SITES")
  local sites = SDP_Panel.Sites
  Set(sites, 4, 6)
  local result = Solve(sites)
  T.ok(#result.Solutions[1].Sites == 4, "four sites")
  local reordered = CheckOrder(result, 6, Anchors())
  T.ok(reordered > 0, "some solution's order is not the plot order")
  CheckRowsAndTacks(sites, result, 1)
  SDP_Panel.Close()
end)

test("a site that links back only through another site comes after it, even when worth more", function()
  -- Our capital at (3, 13) at the foot of a land strip running north; the
  -- rest mountains. With a farthest distance of 4, a site near the top
  -- links back only through one halfway up. The top has wine, horses and
  -- a river: worth more than the halfway site, and first in plot order.
  local rows = {}
  for y = 0, 15 do rows[y + 1] = (y >= 1 and y <= 14) and "MM....MMMMMM" or "MMMMMMMMMMMM" end
  local rivers = {}
  for y = 1, 4 do rivers[#rivers + 1] = "3," .. y end
  Setup({
    rows = rows, rivers = rivers,
    cities = { { id = 1, x = 3, y = 13, population = 6, capital = true, radius = 1 } },
    resources = { { 2, 2, "RESOURCE_WINE", 1 }, { 4, 2, "RESOURCE_WINE", 1 }, { 2, 3, "RESOURCE_HORSES", 1 },
      { 5, 1, "RESOURCE_IRON", 1 } },
  })
  SDP_Panel.Open()
  SDP_Panel.SelectTab("SITES")
  local sites = SDP_Panel.Sites
  Set(sites, 2, 4)
  local result = Solve(sites)
  local anchors = Anchors()
  CheckOrder(result, 4, anchors)
  local checked = 0
  for n, solution in ipairs(result.Solutions) do
    if #solution.Sites == 2 then
      local first, second = solution.Sites[1], solution.Sites[2]
      local far = true
      for _, a in ipairs(anchors) do
        if Map.GetPlotDistance(second.X, second.Y, a.X, a.Y) <= 4 then far = false end
      end
      if far and second.Value > first.Value and second.Index < first.Index then checked = checked + 1 end
    end
  end
  T.ok(checked > 0, "a solution whose second site links back only through the first, worth more and first by plot")
  CheckRowsAndTacks(sites, result, 1)
  SDP_Panel.Close()
end)
