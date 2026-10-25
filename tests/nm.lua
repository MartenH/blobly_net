-- @project ../projects/nm-demo/nm-demo.blobnet
-- Network management from a script: the demo recording replayed onto the in-process bus at 4x,
-- and the cluster read as the Network Management panel reads it, configured by the system.toml
-- beside the project (sysnode, domain and zone_a declared on bus body).

local function raises(fn, text)
  local ok, err = pcall(fn)
  check.truthy(not ok, "refused")
  check.truthy(string.find(tostring(err), text, 1, true), tostring(err) .. " names " .. text)
end

local function names(list) return table.concat(list, ",") end

test("the cluster wakes, is kept awake, releases and sleeps", function()
  nm.listen("body")
  local r = replay.start("body", { speed = 4, loop = false })
  local w = nm.expect_state("body", "awake", 3000, { "sysnode", "domain" })
  check.equal(names(w.kept_awake_by), "sysnode,domain", "declared order")
  check.equal(w.woken_by, "sysnode")
  check.truthy(w.woken_active, "sysnode said active wake-up")
  check.equal(w.source, "system.toml")
  check.equal(w.cluster, "NM ids 0x500..0x53F")
  check.equal(names(w.missing), "zone_a")
  local sys
  for _, n in ipairs(w.nodes) do if n.name == "sysnode" then sys = n end end
  check.equal(sys.nid, 0x11)
  check.equal(sys.can_id, 0x511)
  check.truthy(sys.bits.repeat_request and sys.bits.active_wakeup, "the first frame bits")
  local k = nm.expect_state("body", "awake", 8000, { "sysnode" })
  check.equal(names(k.unknown), "NID 0x22", "the reporter nothing declares")
  nm.expect_state("body", "releasing", 8000)
  local a = nm.expect_asleep("body", 4000)
  check.equal(#a.kept_awake_by, 0)
  local again = nm.expect_state("body", "awake", 6000)
  check.equal(again.woken_by, "domain")
  for _, n in ipairs(again.nodes) do
    if n.name == "domain" then check.equal(n.pn, 5, "partial networks 0 and 2") end
  end
  r:stop()
end)

test("a wait that is not met says what the reading was", function()
  raises(function() nm.expect_state("body", "awake", 50, { "zone_a" }) end, "no NM state awake")
  raises(function() nm.expect_state("body", "dozing", 50) end, "awake, releasing or asleep")
end)

test("a range the script states reads without names", function()
  nm.listen("body", { lo = 0x510, hi = 0x512, timeout_ms = 300 })
  local r = replay.start("body", { speed = 4, loop = false })
  local w = nm.expect_state("body", "awake", 3000)
  check.equal(w.source, "script")
  check.equal(#w.missing, 0, "a stated range declares nobody")
  r:stop()
  for _, n in ipairs(nm.reading("body").nodes) do
    check.equal(n.name, "NID 0x11", "only 0x511 is in the range")
  end
  raises(function() nm.listen("body", { lo = 0x600, hi = 0x500 }) end, "above hi")
  raises(function() nm.listen("body", { lo = 1 }) end, "a range is")
end)

test("nm.listen with no range goes back to the wire configuration", function()
  nm.listen("body")
  check.equal(nm.reading("body").source, "system.toml")
end)
