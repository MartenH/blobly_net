# Releasing Blobly Net

A release is one command against a merged `main`. Everything else is machinery that either
proves the command was legitimate or does the packaging for you.

## The short version

```sh
# 0. (later releases) land a PR that bumps `version:` in v.mod — the ONE version statement;
#    the binary decodes it for `--version` and the window title, so there is nothing else
#    to bump.
git fetch origin
git tag v0.1.0 origin/main      # the tag must match v.mod, on a commit that is ON main
git push origin v0.1.0
```

Watch the **release** workflow run. When it finishes, the release is on the
[Releases page](../../../releases) with two assets:

- `blobly_net-v0.1.0-linux-x64.tar.gz` — needs the distro runtime
  (`sudo apt install libglfw3 libfreetype6 libgl1`)
- `blobly_net-v0.1.0-windows-x64.zip` — self-contained

Both carry the demo projects, DBCs, samples, docs, `README.txt`, `VERSION.txt`, LICENSE and
third-party notices, under one top-level folder. **No vendor CAN DLL is ever included** —
`vxlapi64.dll`, `PCANBasic.dll`, `canlib32.dll` come with the vendor's driver installs, and
the Vector XL terms forbid redistributing theirs.

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
