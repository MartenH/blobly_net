-- @project ../projects/replay-demo.blobnet
-- A script drives the replay of REPLAY1's recording (samples/demo.log: 0x100 and 0x700 at 10 Hz
-- for 2.9 s) and records the wire to a candump file.

local function drain(channel, quiet_ms)
  local got = {}
  while true do
    local f = bus.recv(channel, quiet_ms)
    if not f then return got end
    got[f.id] = (got[f.id] or 0) + 1
  end
end

local function raises(fn, text)
  local ok, err = pcall(fn)
  check.truthy(not ok, "refused")
  check.truthy(string.find(tostring(err), text, 1, true), tostring(err) .. " names " .. text)
end

test("a replay plays the row recording and finishes", function()
  drain("REPLAY1", 0)
  local r = replay.start("REPLAY1", { speed = 20, loop = false })
  check.equal(r.notes[1], "REPLAY1: 60 frames, 0 withheld")
  check.truthy(r:wait_done(5000), "a non-looping replay runs out")
  local got = drain("REPLAY1", 50)
  check.equal(got[0x100], 30)
  check.equal(got[0x700], 30)
  local st = r:stop()
  check.equal(st.state, "finished")
  check.equal(st.sent, 60)
  check.equal(st.passes, 1)
  check.truthy(st.ended)
end)

test("pause, seek, speed and loop are applied before they return", function()
  local r = replay.start("REPLAY1", { paused = true })
  check.equal(r:status().state, "paused")
  r:seek(2.5)
  check.equal(r:status().position, 2.5)
  r:speed(10)
  r:loop(false)
  local st = r:status()
  check.equal(st.speed, 10)
  check.equal(st.loop, false)
  drain("REPLAY1", 0)
  r:resume()
  check.truthy(r:wait_done(2000), "0.4 s of recording at 10x")
  local got = drain("REPLAY1", 50)
  check.equal(got[0x100], 5, "the frames from 2.5 s on")
  check.equal(got[0x700], 5)
  r:stop()
  raises(function() r:pause() end, "stopped")
end)

test("the ECU under test is subtracted, and a bad request refused", function()
  raises(function() replay.start("REPLAY1", { exclude = { "SUT" } }) end, "nothing to play")
  raises(function() replay.start("REPLAY1", { exclude = { "Nobody" } }) end, "declares Nobody")
  raises(function() replay.start("REPLAY1", { speed = 0 }) end, "speed")
  raises(function() replay.start("NOPE") end, "unknown channel")
end)

test("a recording says which frames were ours", function()
  local path = os.tmpname()
  local rec = record.start("REPLAY1", path)
  local r = replay.start("REPLAY1", { speed = 50, loop = false })
  check.truthy(r:wait_done(3000))
  r:stop()
  local c = rec:stop()
  check.equal(c.frames, 60)
  check.equal(c.ours, 60)
  local lines, tx = 0, 0
  for line in io.lines(path) do
    lines = lines + 1
    if line:match(" REPLAY1 %x+#%x* T$") then tx = tx + 1 end
  end
  os.remove(path)
  check.equal(lines, 60)
  check.equal(tx, 60)
end)
