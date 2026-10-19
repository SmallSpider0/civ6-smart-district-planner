-- SDP_SiteSolver: picks K new city sites (docs/multicity-design.md 3.5).
--
--   1. Candidates and coarse scores for all (SDP_Sites); fine scores, with
--      the planned districts placed by DMT, for the best M that can link
--      back: within D of one of the player's cities or city-center pins, or
--      of a site refined before them (at most K - 1 relays). Without that
--      rule an explored map gives a top M of far sites that never connect.
--   2. Combinations of K refined sites: farther apart than CITY_MIN_RANGE;
--      every site linked back to one of the player's cities or city-center
--      pins through steps of at most D plots (other new sites may relay).
--   3. A combination's value corrects the sum of its sites' scores: a plot
--      two sites could work goes to the one that loses most without it; a
--      luxury or strategic kind is new only once; two sites' districts on
--      one plot cost the smaller of the two values. Corrections only lower
--      the sum, so the sum of the best remaining scores bounds the search
--      (branch and bound, node budget per tier).
--   4. The N best combinations that differ: each has a site at least two
--      plots from every site of every better one.
-- Same input, same result (constraint 6). The overlay must be installed.

SDP_SiteSolver = {}

local Session = {}
Session.__index = Session

-- request = {
--   PlayerID, Tier, Params (overrides)
--   K            new cities (default 3, at most MAX_K)
--   D            relay distance (default 8)
--   Districts    the plan every site is scored with
--   Weights      SDP_Sites.WEIGHT_KEYS (default the balanced preset)
-- }
SDP_SiteSolver.MAX_K = 6

function SDP_SiteSolver.NewSession(request)
  local self = setmetatable({}, Session)
  local playerID = request.PlayerID
  self.PlayerID, self.Request = playerID, request
  self.Params = SDP_Tiers.Params(SDP_Tiers.Sites, request.Tier, request.Params)
  self.K = math.max(1, math.min(SDP_SiteSolver.MAX_K, request.K or 3))
  self.D = request.D or 8
  self.Stats = { Tier = self.Params.Tier, Candidates = 0, Refined = 0, Nodes = 0, Combinations = 0, Truncated = false,
    Continues = 0, Calls = 0, Tries = 0 }
  local ctx = SDP_Sites.Context(playerID, request)
  self.Ctx = ctx
  local candidates, centers = SDP_Sites.Candidates(playerID, { K = self.K, D = self.D })
  self.Centers = centers
  self.Stats.Candidates = #candidates
  local sites = {}
  for _, candidate in ipairs(candidates) do
    local site = SDP_Sites.Coarse(ctx, candidate, centers)
    if site.Valid then sites[#sites + 1] = site end
    if SDP_Task ~= nil then SDP_Task.Tick(0.2) end
  end
  table.sort(sites, function(a, b)
    if a.Coarse ~= b.Coarse then return a.Coarse > b.Coarse end
    return a.Index < b.Index
  end)
  self.Sites = sites
  -- Hops: relays a site needs to link back (1 = within D of an anchor).
  local anchors = {}
  for _, c in ipairs(centers) do
    if c.Own then anchors[#anchors + 1] = c end
  end
  for _, site in ipairs(sites) do
    if #anchors == 0 then site.Hops = 1 end
    for _, a in ipairs(anchors) do
      if Map.GetPlotDistance(site.X, site.Y, a.X, a.Y) <= self.D then
        site.Hops = 1
        break
      end
    end
  end
  self.Order = {} -- refined sites, in the order they were refined
  self.Refined = 0
  return self
end

-- The best site by coarse score not refined yet that links back.
function Session:NextSite()
  for _, site in ipairs(self.Sites) do
    if site.Hops ~= nil and not site.Refined then return site end
  end
  return nil
end

-- Fine scores for the next linkable sites in coarse order, until `count` are refined.
function Session:Refine(count)
  local ctx = self.Ctx
  if self.Refined >= count or self:NextSite() == nil then return end
  if ctx.Board == nil then
    SDP_Sites.Board(ctx, self.Sites) -- fixed subjects near every candidate
  end
  local siteParams = SDP_Tiers.Params(SDP_Tiers.Single, "FAST", self.Params.Site)
  while self.Refined < count do
    local site = self:NextSite()
    if site == nil then break end
    SDP_Sites.Fine(ctx, site, siteParams)
    site.Refined = true
    self.Refined = self.Refined + 1
    self.Order[self.Refined] = site
    -- A usable site relays for the sites within D of it.
    if site.CenterLegal and site.Fine ~= nil and site.Hops < self.K then
      for _, other in ipairs(self.Sites) do
        if (other.Hops == nil or other.Hops > site.Hops + 1)
            and Map.GetPlotDistance(site.X, site.Y, other.X, other.Y) <= self.D then
          other.Hops = site.Hops + 1
        end
      end
    end
  end
  self.Stats.Refined = self.Refined
end

-- Value of a combination of refined sites (array of indices into
-- self.Pool), with the corrections of the header. Returns the value and
-- the per-site details.
function Session:Value(chosen)
  local ctx, w = self.Ctx, self.Ctx.Weights
  local pool = self.Pool
  -- Who works each plot two sites could reach: the one that loses most
  -- without it, then the nearer center, then the smaller plot index.
  local owner = {}
  for _, s in ipairs(chosen) do
    local site = pool[s]
    for _, p in ipairs(site.Land.Plots) do
      local loss = site.Land.Loss[p.Index]
      local plot = Map.GetPlotByIndex(p.Index)
      local d = Map.GetPlotDistance(site.X, site.Y, plot:GetX(), plot:GetY())
      local cur = owner[p.Index]
      if cur == nil or loss > cur.Loss or (loss == cur.Loss and (d < cur.Distance or (d == cur.Distance and site.Index < pool[cur.Site].Index))) then
        owner[p.Index] = { Site = s, Loss = loss, Distance = d }
      end
    end
  end
  -- Plots built on: every chosen site's center and districts.
  local built, conflict = {}, 0
  for _, s in ipairs(chosen) do
    local site = pool[s]
    built[site.Index] = { Site = s, Value = math.huge }
    for _, d in ipairs(site.Districts) do
      local other = built[d.Index]
      if other ~= nil and other.Site ~= s then
        conflict = conflict + math.min(d.Value or 0, other.Value or 0)
      else
        built[d.Index] = { Site = s, Value = d.Value or 0 }
      end
    end
  end
  local total = 0
  local luxury, strategic = {}, {}
  local details = {}
  for _, s in ipairs(chosen) do
    local site = pool[s]
    local taken = {}
    for _, p in ipairs(site.Land.Plots) do
      local o = owner[p.Index]
      local b = built[p.Index]
      if (o ~= nil and o.Site ~= s) or b ~= nil then taken[#taken + 1] = p.Index end
    end
    local land = SDP_Land.ScoreTaken(site.Land, taken, #taken, {})
    -- Resources on the plots this site works.
    for _, index in ipairs(SDP_Land.Workable(site.Scan)) do
      local o = owner[index]
      if o == nil or o.Site == s then
        local plot = Map.GetPlotByIndex(index)
        local resource = plot:GetResourceType()
        if resource ~= -1 then
          local row = GameInfo.Resources[resource]
          if ctx.Visible[row.ResourceType] then
            local count = math.max(1, plot:GetResourceCount())
            if row.ResourceClassType == "RESOURCECLASS_LUXURY" then
              luxury[row.ResourceType] = (luxury[row.ResourceType] or 0) + count
            elseif row.ResourceClassType == "RESOURCECLASS_STRATEGIC" then
              strategic[row.ResourceType] = (strategic[row.ResourceType] or 0) + (ctx.Extraction[row.ResourceType] or count)
            end
          end
        end
      end
    end
    local value = site.Parts.District + land + site.Parts.Water + site.Parts.Appeal - site.Parts.Penalty
    details[#details + 1] = { Site = site, Land = land, Value = value }
    total = total + value
  end
  local resources = w.AMENITY * SDP_Sites.LuxuryValue(ctx, luxury, {}) + w.STRATEGIC * SDP_Sites.StrategicValue(ctx, strategic, {})
  total = total + resources - conflict
  return total, details, resources, conflict
end

-- Whether every chosen site links back to the player's cities or pins
-- through steps of at most D plots (other chosen sites relay).
function Session:Connected(chosen)
  local anchors = {}
  for _, c in ipairs(self.Centers) do
    if c.Own then anchors[#anchors + 1] = c end
  end
  if #anchors == 0 then return true end
  local pool, reached, frontier = self.Pool, {}, {}
  for _, a in ipairs(anchors) do frontier[#frontier + 1] = { X = a.X, Y = a.Y } end
  local progress = true
  while progress do
    progress = false
    for _, s in ipairs(chosen) do
      if not reached[s] then
        local site = pool[s]
        for _, f in ipairs(frontier) do
          if Map.GetPlotDistance(site.X, site.Y, f.X, f.Y) <= self.D then
            reached[s] = true
            frontier[#frontier + 1] = { X = site.X, Y = site.Y }
            progress = true
            break
          end
        end
      end
    end
  end
  for _, s in ipairs(chosen) do
    if not reached[s] then return false end
  end
  return true
end

local function Earlier(a, b)
  if a.Value ~= b.Value then return a.Value > b.Value end
  for i = 1, #a.Chosen do
    if a.Chosen[i] ~= b.Chosen[i] then return a.Chosen[i] < b.Chosen[i] end
  end
  return false
end

-- Branch and bound over combinations of the refined sites.
function Session:Combine()
  local params, stats = self.Params, self.Stats
  local pool = {}
  for _, site in ipairs(self.Order) do
    if site.CenterLegal and site.Fine ~= nil then pool[#pool + 1] = site end
  end
  table.sort(pool, function(a, b)
    if a.Fine ~= b.Fine then return a.Fine > b.Fine end
    return a.Index < b.Index
  end)
  self.Pool = pool
  local k = math.min(self.K, #pool)
  self.Kept = {}
  if k == 0 then return end
  local minRange = SDP_Sites.MinRange()
  -- Bound: the best remaining scores (pool is sorted best first).
  local prefix = { [0] = 0 }
  for i = 1, #pool do prefix[i] = prefix[i - 1] + pool[i].Fine end
  local function Rest(from, count)
    local to = math.min(#pool, from + count - 1)
    if to < from then return 0 end
    return prefix[to] - prefix[from - 1]
  end
  local keep = params.Keep or 30
  local kept = {}
  local chosen = {}
  local nodeCap = stats.Nodes + params.ComboNodes
  local stopped = false
  local function Leaf()
    stats.Combinations = stats.Combinations + 1
    if SDP_Task ~= nil then SDP_Task.Tick(1) end -- a combination's value: about a unit
    if not self:Connected(chosen) then return end
    local value, details, resources, conflict = self:Value(chosen)
    local entry = { Value = value, Chosen = { unpack(chosen) }, Details = details, Resources = resources, Conflict = conflict }
    local pos = #kept + 1
    while pos > 1 and Earlier(entry, kept[pos - 1]) do
      kept[pos] = kept[pos - 1]
      pos = pos - 1
    end
    kept[pos] = entry
    if #kept > keep then kept[#kept] = nil end
  end
  local function Walk(from, depth, partial)
    if depth == k then
      Leaf()
      return
    end
    stats.Nodes = stats.Nodes + 1
    if SDP_Task ~= nil and stats.Nodes % SDP_Tiers.NODES_PER_UNIT == 0 then SDP_Task.Tick(1) end
    if stats.Nodes > nodeCap then
      stats.Truncated, stopped = true, true
      return
    end
    for i = from, #pool - (k - depth) + 1 do
      if #kept >= keep and partial + Rest(i, k - depth) <= kept[#kept].Value then return end
      local site = pool[i]
      local spaced = true
      for _, s in ipairs(chosen) do
        if Map.GetPlotDistance(site.X, site.Y, pool[s].X, pool[s].Y) <= minRange then
          spaced = false
          break
        end
      end
      if spaced then
        chosen[depth + 1] = i
        Walk(i + 1, depth + 1, partial + site.Fine)
        chosen[depth + 1] = nil
        if stopped then return end
      end
    end
  end
  Walk(1, 0, 0)
  self.Kept = kept
  self.Bound = Rest(1, k)
end

-- First run: refine the best M sites, combine.
function Session:Run()
  self:Refine(self.Params.Refined)
  self:Combine()
end

function Session:CanContinue()
  return self:NextSite() ~= nil
end

-- Continue (design 7.3): refine ContinueSites more sites, combine again.
function Session:Continue()
  if not self:CanContinue() then return false end
  local before = self.Kept[1] and self.Kept[1].Value or nil
  self.Stats.Continues = self.Stats.Continues + 1
  self:Refine(self.Refined + (self.Params.ContinueSites or 20))
  self:Combine()
  self.Converged = before ~= nil and self.Kept[1] ~= nil and self.Kept[1].Value == before
  return true
end

-- Up to N combinations that differ: each has a site at least two plots
-- from every site of every better one (design 3.5).
function Session:Distinct(count)
  local out = {}
  for _, entry in ipairs(self.Kept or {}) do
    if #out >= count then break end
    local distinct = true
    for _, other in ipairs(out) do
      local hasFar = false
      for _, s in ipairs(entry.Chosen) do
        local far = true
        for _, t in ipairs(other.Chosen) do
          if Map.GetPlotDistance(self.Pool[s].X, self.Pool[s].Y, self.Pool[t].X, self.Pool[t].Y) < 2 then far = false end
        end
        if far then hasFar = true end
      end
      if not hasFar then distinct = false end
    end
    if distinct then out[#out + 1] = entry end
  end
  return out
end

-- Result = {
--   Ok, Error ("NO_SITE" when no combination fits), Stats, Session, Quality
--   Solutions  best first: { Value, Resources, Conflict, Sites = { site } }, each
--              site { X, Y, Index, Value, Parts, Districts, Info, Land (its land score here) }
-- }
function Session:Result()
  local ctx = self.Ctx
  if ctx.Board ~= nil then
    self.Stats.Calls = ctx.Board.Calls
    ctx.Board:Clear()
  end
  local result = { Ok = true, Stats = self.Stats, Session = self, Solutions = {} }
  for _, entry in ipairs(self:Distinct(self.Params.Solutions or 3)) do
    local sites = {}
    for n, d in ipairs(entry.Details) do
      local site = d.Site
      sites[n] = { X = site.X, Y = site.Y, Index = site.Index, Value = d.Value, Land = d.Land, Parts = site.Parts,
        Districts = site.Districts, Info = site.Info, Luxury = site.Luxury, Strategic = site.Strategic }
    end
    table.sort(sites, function(a, b) return a.Index < b.Index end)
    result.Solutions[#result.Solutions + 1] = { Value = entry.Value, Resources = entry.Resources, Conflict = entry.Conflict, Sites = sites }
  end
  if #result.Solutions == 0 then result.Ok, result.Error = false, "NO_SITE" end
  local best = result.Solutions[1]
  local gap = nil
  if best and self.Bound and self.Bound > 0 then gap = math.max(0, (self.Bound - best.Value) / self.Bound) end
  result.Quality = { Bound = self.Bound, Gap = gap, Converged = self.Converged, CanContinue = self:CanContinue(),
    Truncated = self.Stats.Truncated, RefinedOnly = true }
  return result
end

-- Expected work in SDP_Tiers units (time estimate, progress bar); rough.
-- `continue`: only the sites one "continue" refines.
function SDP_SiteSolver.EstimateUnits(districts, k, params, continue)
  local sites = continue and (params.ContinueSites or 20) or params.Refined
  local perSite = (params.Site and params.Site.Work or 100) * math.max(1, districts)
  -- Combinations reach about a quarter of C(refined, k) (spacing and the
  -- bound prune the rest); each costs about a unit.
  local refined = continue and (params.Refined + sites) or sites
  local combos = 1
  for i = 1, k do combos = combos * math.max(0, refined - i + 1) / i end
  combos = math.min(params.ComboNodes, combos / 4)
  return 400 + sites * perSite + combos
end

-- The solve itself; the overlay must be installed (SDP_Task jobs, tests).
function SDP_SiteSolver.SolveNow(request)
  local session = SDP_SiteSolver.NewSession(request)
  session:Run()
  return session:Result()
end

function SDP_SiteSolver.Solve(request)
  local ok, result = pcall(SDP_Overlay.With, request.PlayerID, SDP_SiteSolver.SolveNow, request)
  if not ok then return { Ok = false, Error = tostring(result) } end
  return result
end

function SDP_SiteSolver.Continue(result)
  local session = result and result.Session
  if session == nil or not session:CanContinue() then return result end
  local ok, out = pcall(SDP_Overlay.With, session.PlayerID, function()
    session:Continue()
    return session:Result()
  end)
  if not ok then return { Ok = false, Error = tostring(out) } end
  return out
end
