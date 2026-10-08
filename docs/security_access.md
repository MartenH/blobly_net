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
description names no `security_key = "reference"`. It refuses the Unlock and says why. A target
with no description is tried. If it answers `0x35` invalidKey, the panel says that this ECU does
not accept blobly_net's reference key and that its algorithm is the OEM's. A script can supply the
real algorithm (below).

blobly_net's simulated ECUs accept the reference key at every level, in any session.

## Unlocking from the Diagnostics panel

The **General** tab has a security row:

- **level**: 1..8. It starts at the lowest level that the target's description gates anything
  behind (a DID gate or a service row), or at 1 when the target has no description.
- **Unlock**: if the held connection is in the default session (or no session has been set on
  it yet), it first switches to the extended session. It then sends the seed request and answers
  it with the reference key. It is refused for a target whose description names another key.
- **Lock**: returns to the default session (`10 01`), which is the only way UDS takes a level
  back.

The result is written to the response log, and the strip at the top shows `level N unlocked` or
`locked`. A refusal is shown on the strip by its NRC, with what it means. Like every other button
in the panel, Unlock and Lock are refused while the measurement is stopped, and while a script or
flash is using the target.

A DID write whose gate needs a level unlocks the same way, using the same code. The DIDs tab's
write dialog says beforehand which session and level it will set up.

## Unlocking from Lua

```lua
local diag = uds.open("edge", { tx = 0x7C0, rx = 0x7C8 })
diag:session(0x03)                 -- 0x27 is not served in the default session
diag:security_access(0x01)         -- level 1: requestSeed 0x01, sendKey 0x02, reference key
diag:security_access(0x01, function(seed) return my_oem_key(seed) end)  -- any other algorithm
diag:session(0x01)                 -- back to default: locked again
```

`security_access` takes the **seed sub-function** (`2L-1`), not the level number. Without a key
function it uses the reference key. With one, it sends whatever key that function returns, which
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
| `0x35` | invalidKey | the key is wrong; it counts toward the lockout. From an ECU that does not use the reference key, this is the expected answer |
| `0x36` | exceededNumberOfAttempts | too many wrong keys: the ECU is now locked out for its delay |
| `0x37` | requiredTimeDelayNotExpired | the lockout delay (or the delay after power-up) is still running |
| `0x7E` / `0x7F` | …NotSupportedInActiveSession | not served in this session (on blobly_emb, any session but extended) |

On blobly_emb the failed-key count survives an ECU reset, so a reset does not buy more guesses.
