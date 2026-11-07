-- SDP_PageKit: what the planner's three tabs (SDP_PageSingle, SDP_PageSites,
-- SDP_PageMulti) share, so that a change to one of these settings or
-- actions reaches every tab (issue 251): the weights, the tier, the preset,
-- the fold line, the switches kept in the save, and placing and undoing the
-- map tacks of a result. Included by SDP_Panel.lua into its context after
-- the SDP_UI helpers: uses its Controls and SDP_UI.
--
-- A tab makes one kit with SDP_PageKit.New(spec) and keeps its own state
-- (the districts, the cities, the result); the kit holds the tier, the
-- preset and the fold, and reads and writes the tab's weight table and
-- switches through the spec.

SDP_PageKit = {}

-- spec = {
--   Page        the tab's table (its Name: a computation it started is cancelled with ClearResult)
--   Tab, Columns, Weights, Tiers, Presets, Order   as for SDP_UI.Keeper
--   Switches    { Key, Default, Get, Put, Check (the check box, optional),
--                 OnChange(on) (after the result is cleared and the settings kept, optional) }
--   Extra       more kept values ({ Key, Default, Get, Put, ... }, SDP_UI.Keeper); the fold is added here
--   WeightRows  { { IM, Stack, Columns }, ... }: the weight columns, drawn WeightWidth wide
--   TierPull, PresetPull, PresetTips (SDP_UI.ShowPreset's spec)
--   Fold        { Button, Text, Action, Scroll }
--   Buttons     { Solve, Continue, Cancel, Place, Undo }: clicks call Page.Solve, Continue, Place, Undo
--   FoldParts() the fold line's parts (what is not as usual), optional
--   ClearResult()  an input changed
--   Changed()   after the tier changed (the estimate), optional
--   AfterPreset()  after a preset, optional
--   FitPage()
-- }
function SDP_PageKit.New(spec)
  local K = { Tier = SDP_Tiers.DEFAULT, Preset = spec.Preset or SDP_Settings.PRESET_ORDER[1], Fold = false,
    Weights = spec.Weights, Views = {}, Cells = {} }
  local switches = spec.Switches or {}
  local byKey = {}
  for _, switch in ipairs(switches) do byKey[switch.Key] = switch end
  local extra = { { Key = "FOLD", Default = false, Get = function() return K.Fold end, Put = function(v) K.Fold = v end } }
  for _, flag in ipairs(spec.Extra or {}) do extra[#extra + 1] = flag end
  local keeper = SDP_UI.Keeper({ Tab = spec.Tab, Columns = spec.Columns, Weights = spec.Weights, Switches = switches,
    Extra = extra, Tiers = spec.Tiers, Presets = spec.Presets, Order = spec.Order,
    GetTier = function() return K.Tier end, PutTier = function(tier) K.Tier = tier end })
  K.Keeper = keeper

  -- The fold line (issue 71) and the preset pulldown: the preset the values
  -- equal, "Custom" when none (issue 89), then what is not as usual.
  function K.UpdateFold()
    local shown = keeper.Match(K.Preset)
    local fold = spec.Fold
    SDP_UI.ShowFold(fold.Button, fold.Text, fold.Action, fold.Scroll, K.Fold,
      SDP_UI.FoldSummary(shown, spec.FoldParts and spec.FoldParts() or {}))
    SDP_UI.ShowPreset(spec.PresetPull, shown, function(name) K.SetPreset(name) end, spec.PresetTips)
  end

  -- Keep the tab's settings in the save after a change (issue 57), and show
  -- them on the fold line. Values equal to another preset make it the
  -- current one (issue 89).
  function K.Remember()
    K.Preset = keeper.Match(K.Preset) or K.Preset
    keeper.Remember(K.Preset)
    K.UpdateFold()
  end

  -- Read them from the save the first time the panel shows for this player.
  function K.Restore()
    local kept = keeper.Restore()
    if kept ~= nil then K.Preset = keeper.Match(kept.Preset) or kept.Preset end
  end

  function K.SetWeight(key, value)
    value = math.max(0, math.min(SDP_UI.MAX_WEIGHT, value))
    if K.Weights[key] ~= value then
      K.Weights[key] = value
      spec.ClearResult()
      K.Remember()
    end
    if K.Views[key] then K.Views[key]() end
  end

  -- Tests and older callers: the land part on (weight 1 unless it is set) or off (0).
  function K.SetLand(on)
    if on then
      if K.Weights.LAND == 0 then K.SetWeight("LAND", 1) end
    else
      K.SetWeight("LAND", 0)
    end
  end

  -- The weight columns, row after row; K.Cells their controls in order (tests).
  function K.BuildWeights()
    K.Views, K.Cells = {}, {}
    for _, row in ipairs(spec.WeightRows) do
      local views, cells = SDP_UI.BuildWeights(row.IM, row.Stack, row.Columns, K.Weights, nil, K.SetWeight, spec.WeightWidth)
      for key, view in pairs(views) do K.Views[key] = view end
      for _, cell in ipairs(cells) do K.Cells[#K.Cells + 1] = cell end
    end
  end

  function K.SetTier(tier)
    if spec.Tiers[tier] == nil then return end
    if K.Tier ~= tier then
      K.Tier = tier
      spec.ClearResult()
      K.Remember()
    end
    spec.TierPull:GetButton():SetText(Locale.Lookup("LOC_SDP_TIER_" .. tier))
    if spec.Changed then spec.Changed() end
  end

  function K.ShowTiers()
    SDP_UI.PopulateTierPull(spec.TierPull, K.Tier, K.SetTier)
  end

  -- A switch kept in the save: its check box follows; a change clears the result.
  function K.SetSwitch(key, on)
    local switch = byKey[key]
    if switch.Check ~= nil then switch.Check:SetCheck(on) end
    if switch.Get() ~= on then
      switch.Put(on)
      spec.ClearResult()
      K.Remember()
      if switch.OnChange then switch.OnChange(on) end
    end
  end

  -- The check boxes as the switches are.
  function K.ShowSwitches()
    for _, switch in ipairs(switches) do
      if switch.Check ~= nil then switch.Check:SetCheck(switch.Get()) end
    end
  end

  -- A preset (issue 49): its weights and switches; the tier and the fold stay.
  -- The same preset again puts back what was changed (issue 89: no Reset).
  function K.SetPreset(name)
    if not keeper.Use(name) then return end
    K.Preset = name
    spec.ClearResult()
    for _, view in pairs(K.Views) do view() end
    K.ShowSwitches()
    K.Remember()
    if spec.AfterPreset then spec.AfterPreset() end
  end

  -- Every kept setting back to what a game that kept nothing has (the
  -- tests' SDP_Panel.Defaults, issue 327): the save is read first, so it
  -- cannot overwrite these later, then they are kept. The tab draws them
  -- again with its Refresh.
  function K.Defaults()
    K.Restore()
    K.Preset = keeper.Defaults().Preset
    spec.ClearResult()
    K.Remember()
  end

  -- Fold or unfold the settings (issue 71): after a solve, or a click on the line.
  function K.SetFold(on)
    if K.Fold ~= on then
      K.Fold = on
      K.Remember()
    end
    K.UpdateFold()
    spec.FitPage()
  end

  -- A computation this tab started is of no use once an input changed.
  function K.CancelTask()
    local job = SDP_Task.Current()
    if job ~= nil and job.Page == spec.Page.Name then SDP_Task.Cancel() end
  end

  -- The action buttons: `can` = { Solve, Continue, Place } with nothing
  -- running; while a computation runs, Cancel stands in for Continue.
  function K.ShowButtons(can)
    local b, running = spec.Buttons, SDP_Task.IsRunning()
    b.Solve:SetDisabled(running or not can.Solve)
    b.Continue:SetDisabled(running or not can.Continue)
    b.Continue:SetHide(running)
    b.Cancel:SetHide(not running)
    b.Place:SetDisabled(running or not can.Place)
    b.Undo:SetDisabled(running or not SDP_Pins.CanUndo())
  end

  for _, switch in ipairs(switches) do
    local key, check = switch.Key, switch.Check
    if check ~= nil then check:RegisterCheckHandler(function() K.SetSwitch(key, check:IsChecked()) end) end
  end
  spec.Fold.Button:RegisterCallback(Mouse.eLClick, function() K.SetFold(not K.Fold) end)
  local page, b = spec.Page, spec.Buttons
  b.Solve:RegisterCallback(Mouse.eLClick, function() page.Solve() end)
  b.Continue:RegisterCallback(Mouse.eLClick, function() page.Continue() end)
  b.Cancel:RegisterCallback(Mouse.eLClick, function() SDP_Task.Cancel() end)
  b.Place:RegisterCallback(Mouse.eLClick, function() page.Place() end)
  b.Undo:RegisterCallback(Mouse.eLClick, function() page.Undo() end)
  return K
end

-- Whether a result can be placed as map tacks now.
function SDP_PageKit.CanPlace(result)
  return not SDP_Task.IsRunning() and result ~= nil and result.Ok and not result.Placed
end

-- Place `entries` (SDP_Pins.Place) for `result`; `replace`: this mod's
-- earlier pins the plan was made without, removed. The preview goes.
function SDP_PageKit.Place(result, entries, replace)
  local placed = SDP_Pins.Place(Game.GetLocalPlayer(), entries, { Replace = replace })
  result.Placed = true
  SDP_Preview.Clear()
  return placed
end

-- Undo the last tacks placed. When they had replaced earlier pins, those
-- are back (with new IDs) and `onReplaced` runs (plan again); else the
-- shown `result` can be placed once more.
function SDP_PageKit.Undo(result, onReplaced)
  local last = SDP_Pins.LastBatch()
  local removed = SDP_Pins.UndoLast()
  if onReplaced ~= nil and last ~= nil and last.Replaced and #last.Replaced > 0 then
    onReplaced()
  elseif result ~= nil and result.Ok then
    result.Placed = false
  end
  return removed
end
