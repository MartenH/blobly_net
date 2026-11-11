-- @project ../projects/nm-demo/nm-sim.blobnet
-- Simulated nodes announcing NM: sysnode and domain announce on the ids the system.toml gives
-- them, on the 100 ms cycle blobly_emb defaults to, while the run is up; nm.release silences them, nm.request brings
-- them back.

local function names(list) return table.concat(list, ",") end

test("the simulated nodes keep the cluster awake on their declared ids", function()
  local w = nm.expect_state("body", "awake", 2000, { "sysnode", "domain" })
  check.equal(names(w.kept_awake_by), "sysnode,domain", "declared order")
  check.equal(names(w.missing), "zone_a")
  for _, n in ipairs(w.nodes) do
    if n.name == "sysnode" then
      check.equal(n.can_id, 0x511)
      check.equal(n.nid, 0x11)
      check.equal(n.bits.raw, 0)
    end
  end
  local r = nm.reading("body", 600)
  for _, n in ipairs(r.nodes) do
    if n.name == "domain" then
      check.truthy(n.cadence_ms > 80 and n.cadence_ms < 130, "the 100 ms cycle, read " .. n.cadence_ms)
    end
  end
end)

test("released, the cluster sleeps; requested, it wakes", function()
  nm.expect_state("body", "awake", 2000)
  check.equal(nm.release("body"), 2)
  nm.expect_asleep("body", 2000)
  check.equal(nm.request("body"), 2)
  nm.expect_state("body", "awake", 2000, { "sysnode", "domain" })
end)
