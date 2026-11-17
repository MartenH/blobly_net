# Security access

UDS SecurityAccess (service `0x27`) is how a tester earns the right to use a service or a DID that
an ECU keeps behind a lock. This page covers what a level is, how blobly_emb declares levels, the
key blobly_net computes, and how to unlock from the Diagnostics panel and from Lua.

## Levels

A **security level** is one lock. Level `L` is opened by two requests:

| step | request | sub-function |
|---|---|---|
| requestSeed | `27 <2L-1>` | odd: `01` for level 1, `03` for level 2, … |
| sendKey | `27 <2L> <key>` | even: `02` for level 1, `04` for level 2, … |

The ECU answers the seed request with a random **seed**. The tester computes a **key** from it and
sends it back. If the key is right, the level is unlocked. A seed of all zeros means the level is
already unlocked, and no key is sent.

ISO 14229-1 does not serve `0x27` in the default session, so a tester switches to the extended
session first (`10 03`). **Every session change locks the ECU again**, and that includes
re-entering the session it is already in. UDS has no "lock" request: returning to the default
session (`10 01`) is how a level is given back.

## How blobly_emb declares levels

A blobly_emb node lists its levels in its `ecu.toml`, numbered 1..8:

- on a DID, in its `read` / `write` gate: `write = { session = ["extended"], security = 1 }`;
- on a service, as a row of the `[uds] services` table: `"0x11" = { sessions = ["extended"], security = 1 }`.

`[uds] security_attempts` and `security_delay_ms` set how many wrong keys the ECU accepts before it
locks the tester out, and for how long. The server, its evaluation order and the lockout are
described in blobly_emb's
[diagnostics.md](https://github.com/MartenH/blobly_emb/blob/main/docs/diagnostics.md) (§3.1). Every
key, with its default and allowed values, is in
[config-reference.md](https://github.com/MartenH/blobly_emb/blob/main/docs/config-reference.md).

## The reference key, and why it is bench-only

blobly_net computes one key algorithm, the **reference key**: `key[i] = seed[i] XOR 0xFF`. It is
public, so it proves nothing about who the tester is. A blobly_emb node accepts it only when its
description says so by name:

- `[uds] security_key = "reference"`; without it, the key is the OEM's (`diag_sa_key_ok`, a board
  seam) and blobly_net cannot compute it;
- on a node reachable over DoIP, additionally `[doip] allow_bench_key = true`. Over a routed
  network a public key authenticates nobody, so the node has to opt into it explicitly.

A production ECU uses its own algorithm, and blobly_net does not have it. Every wrong key counts
toward the ECU's lockout, so the panel does not send the reference key to a target whose
description names no `security_key = "reference"`, or to a DoIP target whose description does
not opt in with `allow_bench_key`. It refuses the Unlock and says why. A DID write's unlock
follows the same rule. A target
with no description is tried. If it answers `0x35` invalidKey, the panel says that this ECU does
not accept blobly_net's reference key and that its algorithm is the OEM's. A script can supply the
real algorithm (below).

blobly_net's simulated ECUs with no description accept the reference key at every level, in
any session. A simulated ECU described by a blobly_emb `ecu.toml` follows that description
instead: it serves 0x27 only at the levels its gates name (`0x12` for any other), in the sessions
its `[uds] services` table allows, and accepts the reference key only under the rules above.
Once unlocked, a simulated ECU answers an all-zero seed for that level only (another level gets a
real seed and needs its own key), and a session change locks it again.

## Unlocking from the Diagnostics panel

The **General** tab has a security row:

- **level**: 1..8. It starts at the lowest level that the target's description gates anything
  behind (a DID gate or a service row), or at 1 when the target has no description.
- **Unlock**: if the held connection is in the default session (or no session has been set on
  it yet), it first switches to the extended session. It then sends the seed request and answers
  it with the reference key. It is refused for a target whose description names another key, and
  for a DoIP target whose description lacks `allow_bench_key = true`.
- **Lock**: returns to the default session (`10 01`), which is the only way UDS takes a level
  back.

The result is written to the response log. The strip at the top shows `level N unlocked`, or
`locked` once a session change on this connection has relocked the ECU. Otherwise it shows
`security unknown`: on a fresh connection, because a script or another tester may have left the
ECU unlocked, and after a 0x27 the ECU answered without granting, because that may have relocked
it, or not. A refusal is shown on the strip by its NRC, with what it means. Like every other button
in the panel, Unlock and Lock are refused while the measurement is stopped, and while a script or
flash is using the target.

A DID write whose gate needs a level unlocks the same way, using the same code. The DIDs tab's
write dialog says beforehand which session and level it will set up. A gated write is never
planned in the default session, since 0x27 is not served there. A gate that names a level and only
`session = ["default"]` cannot be met at all, so the write is refused, and the DIDs tab flags the
entry when it reads the description.

## Unlocking from Lua

```lua
local diag = uds.open("edge", { tx = 0x7C0, rx = 0x7C8 })
diag:session(0x03)                 -- 0x27 is not served in the default session
diag:security_access(0x01)         -- level 1: requestSeed 0x01, sendKey 0x02, reference key
diag:security_access(0x01, function(seed) return my_oem_key(seed) end)  -- any other algorithm
diag:session(0x01)                 -- back to default: locked again
```

`security_access` takes the **seed sub-function** (`2L-1`), not the level number. Without a key
function it uses the reference key. An all-zero seed (already unlocked) returns at once, and no key
is computed or sent. With one, it sends whatever key that function returns, which
is how a script unlocks an ECU whose algorithm is not the reference one. A refusal raises a Lua
error. `check.nrc(0x35, function() … end)` expects one. See [scripting.md](scripting.md).

## What the NRCs mean

| NRC | name | for 0x27 |
|---|---|---|
| `0x12` | subFunctionNotSupported | the ECU has no such level |
| `0x13` | incorrectMessageLengthOrInvalidFormat | the key has the wrong length |
| `0x22` | conditionsNotCorrect | the ECU's conditions for unlocking are not met |
| `0x24` | requestSequenceError | a key with no seed outstanding (or a seed request out of order) |
| `0x33` | securityAccessDenied | (on another service) the level it needs is not unlocked |
| `0x35` | invalidKey | the key is wrong; it counts toward the lockout. From an ECU that does not use the reference key, this is the expected answer. It also happens if another tester asked for a seed between this tester's seed and key |
| `0x36` | exceededNumberOfAttempts | too many wrong keys: the ECU is now locked out for its delay |
| `0x37` | requiredTimeDelayNotExpired | the lockout delay (or the delay after power-up) is still running — for a seed request, and for a key answering a seed drawn before the lockout began (over the other transport) |
| `0x7E` / `0x7F` | …NotSupportedInActiveSession | not served in this session (on blobly_emb, any session but extended) |

On blobly_emb the failed-key count since the last correct key survives an ECU reset (and, on a
target, a power cycle), so a reset after a wrong key costs the lockout delay and buys no more guesses.
A count below the limit carries over; after the delay of a count at the limit the level has its
attempts again, as after any lockout. The count and the delay are per level: one level's lockout
never delays another level's seed.

## Authentication (0x29)

A blobly_emb node may unlock its levels with **0x29 Authentication** instead of 0x27: its ecu.toml
says `[uds] access = "authentication"` and gives each gated level the tester's Ed25519 **public**
key (`auth_keys = { "1" = "reference" }`, or 64 hex characters). It is ISO 14229-1's
challenge-response (ACR), unidirectional, with Ed25519, and it grants the **same levels** 0x27
would: the gates, the relock on every session entry, S3 and a reset, and the failed-attempt count
and lockout are the same. Such a node answers 0x27 serviceNotSupported (0x11), and a seed-key node
answers 0x29 the same way. A level is unlocked one way per node.

| Request | Bytes | Answer |
|---|---|---|
| 05 requestChallengeForAuthentication | `29 05 <level> 06 03 2B 65 70 00…00` (19): the level in communicationConfiguration, the Ed25519 OID as algorithmIndicator | `69 05 00 <alg 16> 00 20 <challenge 32> 00 00` (55) |
| 06 verifyProofOfOwnershipUnidirectional | `29 06 <alg 16> 00 40 <signature 64> 00 00 00 00` (88): an Ed25519 signature over exactly the challenge | first `7F 29 78` (responsePending: blobly_emb verifies a slice per pass), then `69 06 12 <alg 16> 00 00` (21): ownershipVerified, the algorithmIndicator, no session key — ISO 14229-1:2020's layout |
| 00 deAuthenticate | `29 00` | `69 00 10`: relocked |

The key is the tester's Ed25519 **seed** (32 bytes). By name, `"reference"` (or nothing) is
blobly_emb's dev tester seed, `examples/keys/tester.seed` — the key a bootloader's `session_key` and
an application's `auth_keys "reference"` both trust. Like the 0x27 reference key it is public, so a
`[doip]` node accepts it only with `allow_bench_key = true`. Otherwise the key is 64 hex characters
(exactly: a hex key of another length is refused, naming its length) or a seed file's path.

```lua
local d = uds.open("AUTH", { tx = 0x7E0, rx = 0x7E8 })
d:session(0x03)                                  -- not served in the default session
d:authenticate(1)                                -- the dev tester key
d:authenticate(1, { key = "keys/tester.seed" })  -- a seed file, relative to the script
d:authenticate(1, { key = string.rep("ab", 32) }) -- 64 hex characters
```

```python
with net.channels.AUTH.uds() as d:
    d.session(0x03)
    d.authenticate(1)                      # the dev tester key
    d.authenticate(1, key="tester.seed")   # or 32 bytes, or 64 hex characters
```

From C, `bb_uds_authenticate(u, level, seed, n)` (NULL and 0: the dev key) and
`bb_tester_seed(spec, buf, cap)` to resolve a key spec. `node.authenticates` (Python, `bb_node`)
says whether a described node unlocks this way. Both helpers are `uds.Client.authenticate`, which
signs through `uds.proof_of` — the one signing site, which `blobly/flash` uses too for the
bootloader's own profile (01 challenge, 02 proof).

| NRC | name | for 0x29 |
|---|---|---|
| `0x12` | subFunctionNotSupported | a sub-function other than 00, 05, 06 |
| `0x13` | incorrectMessageLengthOrInvalidFormat | not the sub-function's exact length, or 06 with a proof length other than 64, a client challenge or an additional parameter |
| `0x24` | requestSequenceError | a proof with no challenge outstanding — after a session entry, a reset, 00, a new 05, or on a NEW connection (the challenge ends with the connection that asked it) |
| `0x31` | requestOutOfRange | an algorithm other than Ed25519, or a level the node does not serve (0, above 8, ungated, or with no key) |
| `0x37` | requiredTimeDelayNotExpired | the level's lockout delay is still running (05 refused; a 06 answering a challenge drawn before the lockout began, over the other transport, refused too — not verified, not counted, the challenge void) |
| `0x58` | ownershipVerificationFailed | the proof is wrong; it counts toward the lockout like a wrong 0x27 key |
| `0x36` | exceededNumberOfAttempts | the failed proof that reached the limit: the level's lockout starts |
| `0x59` | challengeCalculationFailed | the ECU's random source failed |
| `0x14` | responseTooLong | the answer does not fit what the transport carries — a valid proof then unlocks nothing and is not counted |
| `0x7F` | serviceNotSupportedInActiveSession | not in the default session |

The **simulated** node answers 0x29 as the board does when its description says
`access = "authentication"` (blobly/uds described.v), and its DoIP entity ends a connection's
challenge, unlock and session when the tester disconnects (`connection_dropped`), as the board's
`remote_dropped` does — `projects/auth-demo` is such a node on CAN and DoIP. The Diagnostics panel
does **not** offer 0x29 yet: its Unlock, and a gated DID write, refuse such a node by one text that
points at a script; a write plan (`uds.write_plan_by`, a script's `WriteGated`) names the 0x29 step.
