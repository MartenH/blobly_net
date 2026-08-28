# Releasing Blobly Net

A release is one command against a merged `main`. Everything else is machinery that either
proves the command was legitimate or does the packaging for you.

## The short version

```sh
# 0. Land a PR that bumps `version:` in v.mod — the ONE version statement; the binary decodes
#    it for `--version` and the window title, so there is nothing else to bump. (v0.1.0 was
#    cut 2026-08-21; every release since starts here.)
git fetch origin
git tag vX.Y.Z origin/main      # the tag must match v.mod, on a commit that is ON main
git push origin vX.Y.Z
```

Watch the **release** workflow run. When it finishes, the release is on the
[Releases page](../../../releases) with two assets:

- `blobly_net-vX.Y.Z-linux-x64.tar.gz` — needs the distro runtime
  (`sudo apt install libglfw3 libfreetype6 libgl1`)
- `blobly_net-vX.Y.Z-windows-x64.zip` — self-contained

Both carry the demo projects, DBCs, samples, docs, `README.txt`, `VERSION.txt`, LICENSE and
third-party notices, under one top-level folder. **No vendor CAN DLL is ever included** —
`vxlapi64.dll`, `PCANBasic.dll`, `canlib32.dll` come with the vendor's driver installs, and
the Vector XL terms forbid redistributing theirs.

## Next time — the checklist

The tag is the last step. What came before it for `v2026.08.00`, so the next release does not
have to rediscover it:

1. **Decide the number** (rule below: this month, next patch), and check the previous tag:
   `git tag --sort=-v:refname` (ignore `v-toolchain`). The changelog GitHub generates spans
   every PR since that tag.
2. **Audit the docs against the code** — README, ROADMAP, CLAUDE.md, `docs/*.md`,
   `packaging/RELEASE_NOTES_HEADER.md`. Read each for claims that a shipped feature is planned,
   counts that have drifted, names of files or functions that no longer exist, and issue
   numbers stated as open (`gh issue view N --json state`). At `v2026.08.00` this found ~70 such
   statements across 19 files, including a hardware guide that still said the Vector backend
   was not implemented. Fix, do not annotate; a design document that shipped differently gets
   one note at its top saying so.
3. **One PR**: the audit, then `v.mod` bumped **in its own commit** so `git log v.mod` explains
   itself. Build the GUI and check `./build/blobly_net --version` prints the new number —
   `release.yml` refuses a tag that disagrees with it. The usual gate: `/code-review high`, then
   `@codex review` until clean, CI green.
4. **Merge everything meant for the release first**, then that PR last (a PR merged after the
   bump but before the tag is still in the release; one merged after the tag is not).
5. **Tag** from `origin/main`, never from a local branch, and push it (the short version above).
   Watch the `release` workflow: the Windows bundle takes the better part of an hour.
6. **After it publishes**, edit the release description on GitHub if one change deserves a
   headline above the generated list — the header is a standing statement, not a summary of
   the version.

## The number — CalVer, `YYYY.MM.PATCH`

Adopted at `v2026.08.00`. A release is a snapshot of `main`, not a promise about what changed
(the README says so), so the number says *when*, and nothing else:

- `YYYY.MM` is the month the tag is cut; `PATCH` counts releases within that month from `00`:
  `v2026.08.00`, then `v2026.08.01`, and the first in September is `v2026.09.00`. Zero-padded
  on both, so tags read and sort uniformly.
- Not the day: the tag already carries its date, and a day in the number is wrong the moment a
  build slips past midnight or is re-tagged the next morning.
- An incompatible `.blobnet` schema change, or a change to a wire format shared with blobly_emb,
  is called out in the release description — with this scheme that line is the only warning a
  user gets, so it is not optional.

The machinery does not care about the scheme (the guard compares the tag to `v.mod` as a
string, `v.mod` takes any quoted string, the trigger is `v[0-9]*`, the changelog baseline is
the previous tag by version sort). It does care about direction: a date sorts above every
`0.x` number, so `v0.1.0` stays the baseline of nothing from now on, and going back to
`0.x`-style numbers would need the workflow's baseline rule changed first.

## What the workflow proves before publishing

`release.yml` refuses rather than trusts, in this order:

1. **tag = v.mod** — a tag that disagrees with the committed version fails immediately, so
   the tag and what the binary reports cannot drift. (Trigger is `v[0-9]*`, so the
   `v-toolchain` CI tag can never fire it.)
2. **the commit is on `main`** — releases come from reviewed history only. The Windows
   bundle publishes for a tag *only* when `release.yml` calls `windows.yml` with
   `publish_bundle=true`, which happens behind this guard — a manual dispatch pointed at a
   tag publishes nothing.
3. **the built binary answers with the tag** — the Linux job runs
   `./blobly_net --version` and compares. (The Windows exe compiles the same committed
   `v.mod`, so one execution covers both.)
4. **the tag still is what the guard proved** — re-checked just before publish, because the
   Windows build runs for the better part of an hour and a deleted or force-moved tag must
   not associate the binaries with different source (`--verify-tag` blocks gh's silent
   tag re-creation too).

## Release notes — automatic

The published notes are `packaging/RELEASE_NOTES_HEADER.md` — the standing statement of what
the version's claims rest on (CI-verified virtual paths, bench-exercised SocketCAN,
hand-verified Windows vendor backends, the no-vendor-DLL rule, the Linux runtime packages),
with its evidence link pinned to the released tag — followed by **GitHub's generated
changelog of every PR merged since the previous product release** (baselined on the highest
`v[0-9]*` tag that is an ancestor; the first release says "First release" instead). Edit the
release on GitHub afterwards if you want to add anything by hand.

## If something goes wrong

- **Guard fails** — the message says which invariant broke (tag/version mismatch, or the
  commit is not on main). Fix, delete the tag **both places** — remote and local, or the
  re-tag fails with "already exists":
  `git push --delete origin vX.Y.Z && git tag -d vX.Y.Z` — then re-tag.
- **A build fails after the guard** — nothing was published; re-tagging the same name after
  a fix cancels the superseded run (there is a concurrency group) and starts fresh.
- **Publish fails after a release exists** — `gh release create` is not idempotent; delete
  the half-made release on GitHub before re-running.

Bundle contents are staged by `scripts/stage_bundle.sh` — one list for both archives; add new
shipped files there, never in a workflow.
