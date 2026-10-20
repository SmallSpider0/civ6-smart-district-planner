-- SDP_Remind: woods and rainforest a plan takes adjacency from (feedback
-- item 5). DMT scores a plan with the map as it is; a builder clearing such
-- a feature later costs the district that adjacency. The planner marks those
-- plots with a reminder pin (SDP_Pins.REMIND_ICON).
--
-- For each planned district, every adjacent plot with a removable feature
-- (GameInfo.Features.Removable) that the plan does not build on is tried:
-- DMT scores the district again with that plot's feature hidden
-- (SDP_Overlay.HideFeature). What it loses, whatever the rule (feature
-- adjacency rows, civilization or pantheon modifiers), is the reminder.
-- Rules count features in steps ("+1 per two woods"), so a single plot often
-- costs nothing on its own: only plots whose loss is at least 1 are kept.
-- The overlay must be installed and hold nothing at the plan's plots.

SDP_Remind = {}

-- plan: { { Type, Kind ("DISTRICT" | "WONDER"), X, Y } }. Returns
-- { { X, Y, Index, Feature, Losses = { { Type, X, Y, Yields (lost, > 0) } } } }
-- sorted by plot index.
function SDP_Remind.Find(playerID, plan)
  local planned, subjects = {}, {}
  for _, p in ipairs(plan) do
    planned[Map.GetPlotIndex(p.X, p.Y)] = true
    subjects[#subjects + 1] = { Key = p.Type, Type = p.Kind or "DISTRICT", X = p.X, Y = p.Y }
  end
  for _, subject in ipairs(subjects) do SDP_Overlay.Set(subject.X, subject.Y, subject) end
  local ok, out = pcall(function()
    local base = {}
    for d, subject in ipairs(subjects) do
      if subject.Type == "DISTRICT" then
        local good, yields = pcall(GetBonusYields, playerID, subject)
        base[d] = good and yields or {}
      end
    end
    local plots, seen = {}, {}
    for d, subject in ipairs(subjects) do
      if base[d] ~= nil then
        for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
          local n = Map.GetAdjacentPlot(subject.X, subject.Y, direction)
          if n ~= nil and not seen[n:GetIndex()] and not planned[n:GetIndex()] then
            seen[n:GetIndex()] = true
            local feature = n:GetFeatureType()
            local row = feature ~= -1 and GameInfo.Features[feature] or nil
            if row ~= nil and row.Removable and not n:IsCity() and n:GetDistrictType() == -1 and n:GetWonderType() == -1 then
              plots[#plots + 1] = { Plot = n, Feature = row.FeatureType }
            end
          end
        end
      end
    end
    table.sort(plots, function(a, b) return a.Plot:GetIndex() < b.Plot:GetIndex() end)
    local found = {}
    for _, entry in ipairs(plots) do
      local q = entry.Plot
      SDP_Overlay.HideFeature(q:GetIndex())
      local losses = {}
      for d, subject in ipairs(subjects) do
        if base[d] ~= nil and Map.GetPlotDistance(subject.X, subject.Y, q:GetX(), q:GetY()) == 1 then
          local good, yields = pcall(GetBonusYields, playerID, subject)
          if good then
            local lost, any = {}, false
            for _, yieldType in ipairs(SDP_Rules.YIELDS) do
              local diff = (base[d][yieldType] or 0) - (yields[yieldType] or 0)
              if diff >= 1 then lost[yieldType], any = diff, true end
            end
            if any then losses[#losses + 1] = { Type = subject.Key, X = subject.X, Y = subject.Y, Yields = lost } end
          end
        end
      end
      SDP_Overlay.HideFeature(nil)
      if #losses > 0 then
        found[#found + 1] = { X = q:GetX(), Y = q:GetY(), Index = q:GetIndex(), Feature = entry.Feature, Losses = losses }
      end
    end
    return found
  end)
  SDP_Overlay.HideFeature(nil)
  for _, subject in ipairs(subjects) do SDP_Overlay.Set(subject.X, subject.Y, nil) end
  if not ok then error(out, 0) end
  return out
end
