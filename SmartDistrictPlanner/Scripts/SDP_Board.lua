-- SDP_Board: incremental, memoized DMT evaluation of a layout.
--
-- A layout puts planned subjects (districts, wonders) on the overlay, one per
-- slot; fixed subjects (built districts, city centers, locked pins) never
-- move. The board's total is
--   sum of the planned subjects' weighted scores
--   + sum over fixed subjects of (score now - score with nothing planned),
-- the same quantity as SDP_Overlay.Evaluate's Total minus the baseline.
--
-- Why it is cheap: DMT's GetBonusYields reads a subject's own plot and its
-- six adjacent plots only (dmt_yieldcalculator.lua, GetBonusYields loops over
-- Map.GetAdjacentPlots). A subject's score is therefore a function of (its
-- key, its plot, the planned subjects on its six neighbours). The board
--   - rescores only subjects whose neighbourhood changed since last time;
--   - remembers every (key, plot, neighbourhood) score it asked DMT for, so a
--     neighbourhood seen before costs no DMT call at all.
-- Legality (CanPlacePin) of a district depends on its own plot and on city
-- centers next to it or within three plots, never on other planned
-- districts (CanPlaceDistrictCheckHelper), so it is asked once per
-- (district, plot). A wonder can require an adjacent district
-- (IsAdjacentToDistrict reads the overlay), so its legality is remembered per
-- neighbourhood like a score. Planned city centers are not supported.
-- Exceptions to locality (one dam per river) are caught by the final full
-- evaluation the solvers do; tests/test_incremental.lua checks the
-- assumptions against full evaluations in the game.
--
-- Requires the overlay installed (SDP_Overlay). Every DMT call is counted
-- and reported to SDP_Task.Tick, the unit of work for frame slicing.

SDP_Board = {}

local Board = {}
Board.__index = Board

local RADIX = 64          -- neighbourhood code: one base-64 digit per direction
local MAX_TYPES = RADIX - 1

local function Memo(root, plot, id)
  local byPlot = root[plot]
  if byPlot == nil then
    byPlot = {}
    root[plot] = byPlot
  end
  local byId = byPlot[id]
  if byId == nil then
    byId = {}
    byPlot[id] = byId
  end
  return byId
end

local function Tick(units)
  if SDP_Task ~= nil then SDP_Task.Tick(units) end
end

-- New board. `fixed` are the subjects already on the map whose scores count
-- (SDP_Overlay.FixedSubjects). Their baseline scores come from `bases`
-- (aligned with `fixed`, e.g. from SDP_Overlay.Evaluate({}, fixed, weights))
-- or are asked for now, so the layer must not hold planned subjects yet.
function SDP_Board.New(playerID, fixed, weights, bases)
  local self = setmetatable({
    PlayerID = playerID,
    Weights = weights,
    Calls = 0,          -- DMT calls: GetBonusYields + CanPlacePin
    Hits = 0,           -- scores served from the memo
    Errors = 0,         -- DMT errors (the subject scored 0)
    typeIds = {}, typeCount = 0,
    neighbours = {},    -- [plot] = { plot index or false, x6 } in direction order
    fixedAt = {},       -- [plot] = { Subject, Id, Base, Score }
    slots = {},         -- [slot] = { Subject, Plot, Id, Score, Legal, Fresh }
    slotAt = {},        -- [plot] = slot
    dirty = {}, dirtyList = {},
    memo = {},          -- [plot][id][code] = score
    legalMemo = {},     -- [plot][id][code] = bool (code 0 unless legality depends on neighbours)
    total = 0, illegal = 0,
    cacheDirty = true,
  }, Board)
  for f, subject in ipairs(fixed) do
    local plot = Map.GetPlotIndex(subject.X, subject.Y)
    if self.fixedAt[plot] == nil then
      local entry = { Subject = subject, Id = self:TypeId(subject.Key) }
      if bases ~= nil and bases[f] ~= nil then
        Memo(self.memo, plot, entry.Id)[0] = bases[f]
        entry.Base = bases[f]
      else
        entry.Base = self:Score(plot, entry.Id, subject, 0)
      end
      entry.Score = entry.Base
      self.fixedAt[plot] = entry
    end
  end
  return self
end

function Board:TypeId(key)
  local id = self.typeIds[key]
  if id == nil then
    if self.typeCount >= MAX_TYPES then error("SDP_Board: too many subject types", 2) end
    self.typeCount = self.typeCount + 1
    id = self.typeCount
    self.typeIds[key] = id
  end
  return id
end

-- Adjacent plot indices of a plot in DMT's direction order (false off map).
function Board:Neighbours(plot)
  local list = self.neighbours[plot]
  if list == nil then
    list = {}
    local p = Map.GetPlotByIndex(plot)
    local x, y = p:GetX(), p:GetY()
    for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
      local n = Map.GetAdjacentPlot(x, y, direction)
      list[direction + 1] = n and n:GetIndex() or false
    end
    self.neighbours[plot] = list
  end
  return list
end

-- The planned subjects around a plot as one number (0: none). Up to 64^6:
-- computed in floating point (exact below 2^53), never in 32-bit integers.
function Board:Code(plot)
  local code, mult = 0, 1.0
  local slots, slotAt = self.slots, self.slotAt
  for _, n in ipairs(self:Neighbours(plot)) do
    if n then
      local slot = slotAt[n]
      if slot ~= nil then code = code + slots[slot].Id * mult end
    end
    mult = mult * RADIX
  end
  return code
end

local function PrepareDMT(self)
  if self.cacheDirty then
    SDP_Overlay.ClearCache()
    self.cacheDirty = false
  end
end

-- Weighted DMT score of `subject` (at `plot`, type `id`) whose neighbourhood
-- is `code`; the layer must match. Second value false on a DMT error.
function Board:Score(plot, id, subject, code)
  local memo = Memo(self.memo, plot, id)
  local hit = memo[code]
  if hit ~= nil then
    self.Hits = self.Hits + 1
    if hit == false then return 0, false end
    return hit, true
  end
  PrepareDMT(self)
  local score, ok = SDP_Overlay.ScoreOf(subject, self.Weights)
  self.Calls = self.Calls + 1
  if not ok then self.Errors = self.Errors + 1 end
  memo[code] = ok and score or false
  Tick(1)
  return score, ok
end

-- DMT legality of a planned subject in its current neighbourhood.
function Board:Legal(plot, id, subject, code)
  if subject.Type ~= "WONDER" then code = 0 end
  local memo = Memo(self.legalMemo, plot, id)
  local hit = memo[code]
  if hit ~= nil then return hit end
  PrepareDMT(self)
  local legal = SDP_Overlay.CanPlace(subject)
  self.Calls = self.Calls + 1
  memo[code] = legal
  Tick(1)
  return legal
end

function Board:Mark(plot)
  if not self.dirty[plot] and (self.slotAt[plot] ~= nil or self.fixedAt[plot] ~= nil) then
    self.dirty[plot] = true
    self.dirtyList[#self.dirtyList + 1] = plot
  end
end

function Board:MarkAround(plot)
  for _, n in ipairs(self:Neighbours(plot)) do
    if n then self:Mark(n) end
  end
end

-- The plot a slot's subject is on, or nil.
function Board:PlotOf(slot)
  local entry = self.slots[slot]
  return entry and entry.Plot or nil
end

-- Whether a plot is taken by a planned or fixed subject.
function Board:IsTaken(plot)
  return self.slotAt[plot] ~= nil or self.fixedAt[plot] ~= nil
end

-- Put `subject` in `slot` (moving it from wherever it was), or take the
-- slot's subject off the map when `subject` is nil. Scores are brought up to
-- date lazily by Total.
function Board:Put(slot, subject)
  local current = self.slots[slot]
  if current ~= nil then
    if subject ~= nil and current.Subject == subject then return end
    if not current.Fresh then
      self.total = self.total - current.Score
      if not current.Legal then self.illegal = self.illegal - 1 end
    end
    self.slotAt[current.Plot] = nil
    self.slots[slot] = nil
    SDP_Overlay.Put(current.Subject.X, current.Subject.Y, nil)
    self:MarkAround(current.Plot)
    self.cacheDirty = true
  end
  if subject ~= nil then
    local plot = Map.GetPlotIndex(subject.X, subject.Y)
    if self.slotAt[plot] ~= nil or self.fixedAt[plot] ~= nil then
      error("SDP_Board: plot " .. plot .. " is taken", 2)
    end
    self.slots[slot] = { Subject = subject, Plot = plot, Id = self:TypeId(subject.Key), Score = 0, Legal = true, Fresh = true }
    self.slotAt[plot] = slot
    SDP_Overlay.Put(subject.X, subject.Y, subject)
    self:Mark(plot)
    self:MarkAround(plot)
    self.cacheDirty = true
  end
end

-- Rescore the subjects whose neighbourhood changed.
function Board:Refresh()
  local list = self.dirtyList
  if #list == 0 then return end
  self.dirtyList = {}
  for _, plot in ipairs(list) do
    self.dirty[plot] = nil
    local slot = self.slotAt[plot]
    if slot ~= nil then
      local entry = self.slots[slot]
      local code = self:Code(plot)
      local score, ok = self:Score(plot, entry.Id, entry.Subject, code)
      local legal = ok and self:Legal(plot, entry.Id, entry.Subject, code)
      if entry.Fresh then
        entry.Fresh = false
        self.total = self.total + score
        if not legal then self.illegal = self.illegal + 1 end
      else
        self.total = self.total + score - entry.Score
        if entry.Legal and not legal then self.illegal = self.illegal + 1 end
        if legal and not entry.Legal then self.illegal = self.illegal - 1 end
      end
      entry.Score, entry.Legal = score, legal
    else
      local entry = self.fixedAt[plot]
      if entry ~= nil then
        local score = self:Score(plot, entry.Id, entry.Subject, self:Code(plot))
        self.total = self.total + score - entry.Score
        entry.Score = score
      end
    end
  end
end

-- Gain of the layout over the fixed subjects' baseline, and whether DMT
-- allows every planned subject where it is.
function Board:Total()
  self:Refresh()
  return self.total, self.illegal == 0
end

-- Take every planned subject off the map.
function Board:Clear()
  local slots = {}
  for slot in pairs(self.slots) do slots[#slots + 1] = slot end
  table.sort(slots)
  for _, slot in ipairs(slots) do self:Put(slot, nil) end
  self:Refresh()
end
