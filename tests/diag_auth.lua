-- @project ../projects/auth-demo/auth-demo.blobnet
-- diag_auth.lua — 0x29 Authentication (ACR with Ed25519) against a simulated node that unlocks that
-- way instead of 0x27 (blobly_emb `[uds] access = "authentication"`), described by
-- projects/auth-demo/nodes/auth/ecu.toml, over CAN and over DoIP.
--   scripts/runtests.sh tests/diag_auth.lua

local function can() return uds.open("AUTH", { tx = 0x7E0, rx = 0x7E8 }) end
local function ip() return uds.open("AUTH_IP") end

local function suite(name, open)
  test(name .. ": 0x27 is not served; authenticate opens the gated DID", function()
    local d = open()
    d:session(0x03)
    check.nrc(0x11, function() d:raw(fromhex("27 01")) end)
    check.nrc(0x33, function() d:read_did(0xF1B0) end)
    d:authenticate(1)
    check.equal(d:read_did(0xF1B0), "SECRET-LEVEL-1")
    d:session(0x03) -- every session entry relocks
    check.nrc(0x33, function() d:read_did(0xF1B0) end)
    d:authenticate(1, { key = "reference" })
    check.equal(tohex(d:raw(fromhex("29 00"))), "69 00 10")
    check.nrc(0x33, function() d:read_did(0xF1B0) end)
  end)

  test(name .. ": failed proofs count like wrong keys, then the lockout", function()
    local d = open()
    d:session(0x03)
    local wrong = string.rep("11", 32)
    check.nrc(0x58, function() d:authenticate(1, { key = wrong }) end)
    check.nrc(0x58, function() d:authenticate(1, { key = wrong }) end)
    check.nrc(0x36, function() d:authenticate(1, { key = wrong }) end)
    check.nrc(0x37, function() d:authenticate(1) end)
    sleep_ms(1100)
    d:authenticate(1)
    check.equal(d:read_did(0xF1B0), "SECRET-LEVEL-1")
  end)
end

suite("CAN", can)
suite("DoIP", ip)

test("a key file is resolved against the script; a short hex key is refused", function()
  local d = can()
  d:session(0x03)
  d:authenticate(1, { key = "auth_keys/tester.seed" })
  check.equal(d:read_did(0xF1B0), "SECRET-LEVEL-1")
  local ok, err = pcall(function() d:authenticate(1, { key = string.rep("1", 63) }) end)
  check.truthy(not ok and tostring(err):find("got 63", 1, true), tostring(err))
end)
