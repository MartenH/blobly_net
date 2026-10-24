-- @project ../projects/j1939-script.blobnet
-- J1939 from a script: the transport protocol rejoined and the address directory, on three rows
-- of one in-process wire. The engine answers nothing on J1939, so the script plays every node:
-- Peer (SA 0x21) and Other (SA 0x00) send, J1939 (its database declares J1939) listens.

local TP_CM, TP_DT, CLAIM = 0xEC00, 0xEB00, 0xEE00

-- the 29-bit id of pgn from sa to da (a PDU2 group keeps its own low byte)
local function jid(prio, pgn, da, sa)
  local pdu1 = ((pgn >> 8) & 0xFF) < 0xF0
  local ps = pdu1 and da or (pgn & 0xFF)
  return (prio << 26) | (((pgn & 0x3FF00) | ps) << 8) | sa
end

local function cm(ch, sa, da, bytes)
  bus.send(ch, jid(7, TP_CM, da, sa), string.char(table.unpack(bytes)), { ext = true })
end

local function announce(ctrl, payload, pgn, b4)
  local n = #payload
  return { ctrl, n & 0xFF, n >> 8, (n + 6) // 7, b4 or 0xFF, pgn & 0xFF, (pgn >> 8) & 0xFF, pgn >> 16 }
end

local function packets(ch, sa, da, payload, skip)
  local seq = 1
  for i = 1, #payload, 7 do
    if seq ~= skip then
      local part = payload:sub(i, i + 6)
      bus.send(ch, jid(7, TP_DT, da, sa), string.char(seq) .. part .. string.rep("\255", 7 - #part), { ext = true })
    end
    seq = seq + 1
  end
end

-- a NAME of identity, function and manufacturer 100, arbitrary-address capable
local function name(identity, fn)
  return string.pack("<I8", identity | (100 << 21) | (fn << 40) | (1 << 63))
end

-- what an earlier test left on a handle
local function drain(ch)
  while bus.recv(ch, 20) do end
  j1939.messages(ch)
  j1939.faults(ch)
end

local BODY = string.char(7) .. string.pack("<I4", 123456) .. string.char(65, 1) ..
  string.rep("\0", 12) .. string.char(0x2A)

test("a BAM is one message, decoded by PGN", function()
  drain("J1939")
  cm("Peer", 0x21, 0xFF, announce(32, BODY, 0xFF10))
  packets("Peer", 0x21, 0xFF, BODY)
  local m = j1939.expect("J1939", 0xFF10, 1000)
  check.equal(m.sa, 0x21)
  check.equal(m.da, 0xFF)
  check.equal(m.bam, true)
  check.equal(m.packets, 3)
  check.equal(m.data, BODY)
  check.equal(m.name, "BodyStatus")
  check.equal(m.signals.Counter, 7)
  check.between(m.signals.Odometer, 12345.5, 12345.7)
  check.equal(m.signals.Tail, 0x2A)
  check.truthy(m.t_start_ms <= m.t_ms, "the announcement before the last packet")
  check.equal(#j1939.faults("J1939"), 0)
end)

test("an RTS/CTS connection, played from both sides", function()
  drain("J1939")
  local payload = string.char(3) .. string.pack("<I2", 1000) .. string.rep("\0", 12) .. string.char(0x99)
  cm("Peer", 0x21, 0x00, announce(16, payload, 0xEF00))
  cm("Other", 0x00, 0x21, { 17, 3, 1, 0xFF, 0xFF, 0x00, 0xEF, 0x00 })
  packets("Peer", 0x21, 0x00, payload)
  cm("Other", 0x00, 0x21, { 19, #payload, 0, 3, 0xFF, 0x00, 0xEF, 0x00 })
  local m = j1939.expect("J1939", 0xEF00, 1000, 0x21)
  check.equal(m.bam, false)
  check.equal(m.da, 0x00)
  check.equal(m.name, "PropA_Cfg")
  check.equal(m.signals.Setpoint, 500)
  check.equal(m.signals.Last, 0x99)
end)

test("a sequence gap is a fault and no message", function()
  drain("J1939")
  cm("Peer", 0x21, 0xFF, announce(32, BODY, 0xFF10))
  packets("Peer", 0x21, 0xFF, BODY, 2)
  local ok, err = pcall(j1939.expect, "J1939", 0xFF10, 300)
  check.truthy(not ok and tostring(err):find("no PGN 0xFF10", 1, true), tostring(err))
  local f = j1939.faults("J1939")
  check.truthy(#f >= 1, "no fault")
  check.equal(f[1].kind, "sequence")
  check.equal(f[1].pgn, 0xFF10)
  check.truthy(f[1].text:find("SA 0x21", 1, true), f[1].text)
  check.equal(#j1939.faults("J1939"), 0)
end)

test("a stalled BAM times out once nothing is queued", function()
  drain("J1939")
  cm("Peer", 0x21, 0xFF, announce(32, BODY, 0xFF10))
  packets("Peer", 0x21, 0xFF, BODY:sub(1, 7))
  check.equal(#j1939.messages("J1939", 900), 0)
  local f = j1939.faults("J1939")
  check.equal(#f, 1)
  check.equal(f[1].kind, "timeout")
end)

test("address claims, and a contested one", function()
  drain("J1939")
  bus.send("Peer", jid(6, CLAIM, 0xFF, 0x80), name(500, 26), { ext = true })
  bus.send("Other", jid(6, CLAIM, 0xFF, 0x00), name(1, 0), { ext = true })
  local a = j1939.addresses("J1939", 200)
  check.equal(#a, 2)
  check.equal(a[1].sa, 0x00)
  check.equal(a[2].sa, 0x80)
  check.equal(a[2].name.function_name, "Body Controller")
  check.equal(a[2].name.identity, 500)
  check.equal(a[1].name.function_name, "Engine")
  -- the engine claims 0x80 too: the lower NAME takes it and leaves 0x00
  bus.send("Other", jid(6, CLAIM, 0xFF, 0x80), name(1, 0), { ext = true })
  a = j1939.addresses("J1939", 200)
  check.equal(#a, 1)
  check.equal(a[1].sa, 0x80)
  check.equal(a[1].name.identity, 1)
end)

test("a channel reads J1939 where its wire says so, any other once asked", function()
  while bus.recv("Other", 20) do end  -- Other has no database; J1939, on its wire, declares it
  cm("Peer", 0x21, 0xFF, announce(32, BODY, 0xFF10))
  packets("Peer", 0x21, 0xFF, BODY)
  local m = j1939.expect("Other", 0xFF10, 1000)
  check.equal(m.name, nil)
  check.equal(m.data, BODY)
  -- Plain: a wire nothing declares J1939; what it read before the ask is not in the reading
  bus.recv("Plain", 0)
  cm("PlainPeer", 0x21, 0xFF, announce(32, BODY, 0xFF10))
  packets("PlainPeer", 0x21, 0xFF, BODY)
  for _ = 1, 4 do check.truthy(bus.recv("Plain", 200), "a frame went missing") end
  check.equal(#j1939.messages("Plain"), 0)
  cm("PlainPeer", 0x21, 0xFF, announce(32, BODY, 0xFF10))
  packets("PlainPeer", 0x21, 0xFF, BODY)
  check.equal(j1939.expect("Plain", 0xFF10, 1000).data, BODY)
end)

test("j1939.expect leaves what follows its match queued", function()
  drain("J1939")
  for counter = 1, 3 do
    cm("Peer", 0x21, 0xFF, announce(32, BODY, 0xFF10))
    packets("Peer", 0x21, 0xFF, string.char(counter) .. BODY:sub(2))
  end
  for _ = 1, 12 do check.truthy(bus.recv("J1939", 200), "a frame went missing") end
  check.equal(j1939.expect("J1939", 0xFF10, 0).signals.Counter, 1)
  local rest = j1939.messages("J1939")
  check.equal(#rest, 2)
  check.equal(rest[1].signals.Counter, 2)
  check.equal(rest[2].signals.Counter, 3)
end)

test("frames read by bus.recv feed the reading", function()
  drain("J1939")
  cm("Peer", 0x21, 0xFF, announce(32, BODY, 0xFF10))
  packets("Peer", 0x21, 0xFF, BODY)
  for _ = 1, 4 do check.truthy(bus.recv("J1939", 200), "a frame went missing") end
  local got = j1939.messages("J1939")
  check.equal(#got, 1)
  check.equal(got[1].pgn, 0xFF10)
end)

test("j1939 refuses what is no PGN and what is no CAN channel", function()
  check.truthy(not pcall(j1939.expect, "J1939", 0x40000, 10), "a PGN past 18 bits")
  check.truthy(not pcall(j1939.messages, "NoSuch"), "an unknown channel")
end)
