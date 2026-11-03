-- @state SDP_Panel
-- @timeout 600
-- Probe (issue 226, not a regular test): dense packing with 12 new cities
-- through the panel on the loaded game; prints the candidates, how many got
-- a coarse score and the result. run_tests.py reports the wall time.
local test, T = ...
local pid = Game.GetLocalPlayer()

test("issue 226 probe: dense packing, 12 new cities, standard tier", function()
  if Players[pid]:GetCities():GetCapitalCity() == nil then T.skip("no capital") end
  local sites = SDP_Panel.Sites
  SDP_Panel.SelectTab("SITES")
  sites.SetDense(true)
  sites.SetCount(12)
  sites.SetTier("STANDARD")
  T.ok(sites.Solve(), "started")
  SDP_Panel.RunTask(2000)
  local result = sites.State().Result
  T.ok(result ~= nil, "a result")
  local st = result.Stats or {}
  print(("ok %s error %s candidates %s scored %s refined %s sites %s"):format(tostring(result.Ok), tostring(result.Error),
    tostring(st.Candidates), tostring(st.Scored), tostring(st.Refined),
    tostring(result.Ok and #result.Solutions[1].Sites or 0)))
  if result.Ok then
    local s = {}
    for _, site in ipairs(result.Solutions[1].Sites) do s[#s + 1] = ("%d,%d"):format(site.X, site.Y) end
    print(("value %.4f sites %s"):format(result.Solutions[1].Value, table.concat(s, " ")))
  end
  sites.SetDense(false)
  sites.SetCount(3)
  SDP_Panel.SelectTab("SINGLE")
end)
