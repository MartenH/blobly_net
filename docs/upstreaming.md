# Upstreaming the W1 patches to vlang/gui & vlang/vglyph

The native-Windows (W1) bring-up surfaced genuine upstream bugs (see
`docs/windows_build.md` for the full story). This doc is the **self-contained
submission record** so any session — fresh box, no memory — can recreate the
branches and open/track the PRs. The fix diffs live in `scripts/win_patches/`
(versioned, so they transfer); the working branches in `~/pr-prep/` do NOT
transfer and are recreated from the patches.

## Contribution facts (checked against the live repos, 2026-06-09)

- **Canonical repos:** `vlang/gui` and `vlang/vglyph`. (`mike-ward/vglyph`
  301-redirects to `vlang/vglyph` — the repo was transferred to the org.)
- **Base branch is `main`** in both (the older note saying `master` was wrong).
- **No CONTRIBUTING.md, no PR template, no CLA, no DCO/sign-off** in either repo.
  So: no `Signed-off-by`, nothing to click through. (Each repo's `CLAUDE.md` is
  an architecture reference, not a contribution policy.)
- **Commit convention = Conventional Commits** (`fix:`, `fix(windows):`), matching
  both repos' history. Our commits already use this.
- **gui CI** (`.github/workflows/ci.yml`, runs on PRs): `v fmt -verify -inprocess`,
  `v check-md`, examples syntax check, and `v test` on **ubuntu + macos (clang)**.
  It does **not** build Windows — so our Windows fixes aren't *exercised* by CI,
  but also can't break it: the `.c` fixes are `#ifdef _WIN32`-gated and the
  titlebar fix is `$if windows`, all inert on ubuntu/macos; `titlebar.c.v` is
  `v fmt`-clean.
- **vglyph has no GitHub Actions** — its verification is an **agent workflow**:
  `.agent/workflows/verify.md` → `v run _check.vsh` (`v fmt . -w`, syntax-check
  every `examples/*.v`, `v test .`, `v check-md .`). So nothing runs on the PR
  automatically; a maintainer runs `_check.vsh` by hand. Run it before/after any
  vglyph PR. Verified on PR 1's branch: `v test .` = **12/12 pass**.
  **`_check.vsh` is RED on vglyph's own `main`** — confirmed under both our old pin
  (de365a1) and latest V (ed17e5f, 2026-06-09): `v -check` reports `unused parameter`
  as a hard **error** in pre-existing code (`accessibility/backend_stub.v`,
  `backend_linux.v`, `load_stroked_glyph`'s `stroke_radius`), and `v fmt . -w`
  reformats a pre-existing long line at `glyph_atlas.v:327`. All of this reproduces
  on **pristine `main` with no PR applied**, so the baseline is already failing —
  newer V (which promotes unused params to errors) outran the repo. **PR 1 is clean
  relative to that baseline: it adds zero new failures, its two added lines are
  `v fmt`-clean (untouched by `v fmt -w`), and it REMOVES the unsafe-cast warning at
  line 418.** So a maintainer running `_check.vsh` sees the same pre-existing noise
  with/without the PR. Gotcha: examples `import vglyph` resolve the module from
  `~/.vmodules/vglyph`, not the cwd — to verify a branch via the example checks,
  point `~/.vmodules/vglyph` at it (apply the patches there, then `git checkout -- .`).
  - Caveat: a *local* `v fmt -verify` on an old V (our 0.5.1 pin) reports ~98
    pre-existing "not vfmt'ed" files on pristine `main` too — that's vfmt
    version skew vs CI's check-latest V, NOT our changes. Verify deltas by
    diffing the flagged-file list against pristine `main`, not the raw count.
- **Flow:** neither account has org push, so it's the standard **fork → push
  branch → PR**. `gh` (authed as `MartenH`, scopes `repo`+`workflow`) does it.

## The PR set — STATUS (updated 2026-06-14)

| PR | Repo | Title | Status (2026-06-14) |
|----|------|-------|---------------------|
| 1 | `vlang/vglyph` | empty-outline + unsafe-cast | **OPEN** — [vglyph#4](https://github.com/vlang/vglyph/pull/4) |
| 4 | `vlang/vglyph` | restore `_check.vsh` green | **OPEN** — [vglyph#5](https://github.com/vlang/vglyph/pull/5) |
| 2 | `vlang/gui` | titlebar_dark isvalid guard | **FILED** — [gui#60](https://github.com/vlang/gui/pull/60) |
| — | `vlang/gui` | WindowCfg.sample_count (MSAA) | **FILED** — [gui#61](https://github.com/vlang/gui/pull/61) (new; was a local-only patch) |
| 3 | `vlang/gui` | windows gcc-16 compile (`#01`+`#02`) | **OBSOLETE** — already upstream (native-Windows work added COBJMACROS + `<stdio.h>`/`<wchar.h>`); do not file |

**Major upstream change (2026-06-11→13):** `vlang/gui` got **native Windows support** merged to `main`
(JalonSolov/GGRei/CreeperFace/Dylan Donnell) + Windows CI; README says "active development". So the
project is being actively maintained again (the "author left → may stagnate" risk is materially lower).
Our gui pin `68b9302` → `main` is now `26f7784`.

**Pin-bump assessment (2026-06-14): GREEN.** Verified our two local gui patches (`gui-closure-reclaim.patch`
incl. the mouse-lock drag guard, `gui-msaa-sample-count.patch`) **apply clean to `main`**, `window_update.v`
**did not drift**, and the app **builds and runs** against gui `main` + patches (isolated VMODULES build;
full layout renders, trace streams, splitter-drag does not crash). Bumping the pin is low-risk — main
blocker is just re-verifying the closure-reclaim behaviour after the bump. The MSAA patch can be dropped
once gui#61 merges.

The ORIGINAL prepared-PR table (for recreating branches from `scripts/win_patches/`):

| PR | Repo | Branch (head) | Base | Commits | Body file |
|----|------|---------------|------|---------|-----------|
| 1 | `vlang/vglyph` | `fix/whitespace-glyph-empty-outline` | `main` | patch #04 + #05 | `scripts/win_patches/pr1-vglyph-glyph-fixes.md` |
| 2 | `vlang/gui` | `fix/windows-titlebar-before-sapp-run` | `main` | patch #03 | `scripts/win_patches/pr2-gui-titlebar.md` |
| 3 | `vlang/gui` | `fix/windows-gcc16-compile` (OBSOLETE) | `main` | patch #01 + #02 | `scripts/win_patches/pr3-gui-gcc16.md` |
| 4 | `vlang/vglyph` | `fix/restore-check-green` | `main` | 15 `_`-prefix renames | `scripts/win_patches/pr4-vglyph-restore-check-green.md` |

PR 4 was discovered while verifying PR 1 with `_check.vsh`: under recent V the
verify gate is red on *pristine* `main` because `v -check -N` errors on 15
pre-existing unused params (`accessibility/*`, `glyph_atlas.v`, two examples). PR 4
`_`-prefixes them — restoring the gate — and is **independent of PR 1** (rebased
onto `main`). Note: do NOT add `v fmt` output to vglyph PRs — current `master`
vfmt is buggy on multi-line calls (inserts a stray blank line inside argument
lists, ~20 files); `_check.vsh`'s `v fmt . -w` step is auto-fix/non-gating, so
formatting is intentionally left untouched.

**Grouping rationale:** PR 2 (titlebar) is a runtime-abort fix affecting *all*
Windows toolchains incl. MSVC; PR 3 (#01/#02) are gcc-16-only *compile* fixes —
different audiences, so split for cleaner review. PR 1 bundles the two vglyph
glyph fixes (both touch `glyph_atlas.v`, neither Windows-specific).

Commit titles (Conventional Commits):
- #04 → `fix: don't panic on whitespace glyphs with empty outlines`
- #05 → `fix: wrap FT_BitmapGlyphRec pointer cast in unsafe`
- #03 → `fix(windows): guard titlebar_dark with sapp.isvalid()`
- #01 → `fix(windows): define COBJMACROS before <d3d11.h> in readback bridge`
- #02 → `fix(windows): include <stdio.h>/<wchar.h> in dialog bridge`

## Recreate the branches from the versioned patches

The patches in `scripts/win_patches/` apply to current `main` (the repos' HEADs
still equal our pins gui@68b9302 / vglyph@5685a6d, so no rebase needed — confirm
with `git ls-remote` first; if HEAD moved, re-check each bug still exists and
rebase). Apply order for vglyph: **#04 then #05** (#05's context follows #04).

```sh
P=/home/mahi/repos/cantester_v/scripts/win_patches
mkdir -p ~/pr-prep && cd ~/pr-prep

# --- vglyph (PR 1) ---
git clone --depth 1 https://github.com/vlang/vglyph vglyph && cd vglyph
git config user.name "Marten Hildell"; git config user.email "marten.hildell@gmail.com"
git checkout -b fix/whitespace-glyph-empty-outline
git apply "$P/04-vglyph-empty-outline.patch"
git commit -am "fix: don't panic on whitespace glyphs with empty outlines

<body — see commit text in this repo's history / regenerate>"
git apply "$P/05-vglyph-unsafe-cast.patch"
git commit -am "fix: wrap FT_BitmapGlyphRec pointer cast in unsafe

<body>"
cd ..

# --- gui (PR 2 + PR 3, two independent branches off main) ---
git clone --depth 1 https://github.com/vlang/gui gui && cd gui
git config user.name "Marten Hildell"; git config user.email "marten.hildell@gmail.com"
# PR 2:
git checkout -b fix/windows-titlebar-before-sapp-run main
git apply "$P/03-gui-titlebar-isvalid.patch"
git commit -am "fix(windows): guard titlebar_dark with sapp.isvalid()  <body>"
# PR 3:
git checkout -b fix/windows-gcc16-compile main
git apply "$P/01-gui-readback-cobjmacros.patch"
git commit "nativebridge/readback_windows.c" -m "fix(windows): define COBJMACROS before <d3d11.h> in readback bridge  <body>"
git apply "$P/02-gui-dialog-includes.patch"
git commit "nativebridge/dialog_windows.c" -m "fix(windows): include <stdio.h>/<wchar.h> in dialog bridge  <body>"
```

(Full commit bodies are in this repo's prepared branches; the one-line summaries
above + the `pr*.md` body files are what the PRs need.)

## Push the fork & open a PR (per repo)

`gh` authed as `MartenH`. Example for PR 1 (vglyph); repeat per row, pushing both
gui branches to the single gui fork:

```sh
export PATH="$HOME/.local/bin:$PATH"
gh repo fork vlang/vglyph --clone=false            # creates MartenH/vglyph (idempotent)
cd ~/pr-prep/vglyph
git remote add fork https://github.com/MartenH/vglyph 2>/dev/null || true
git push -u fork fix/whitespace-glyph-empty-outline
gh pr create --repo vlang/vglyph \
  --base main --head MartenH:fix/whitespace-glyph-empty-outline \
  --title "fix: don't panic on whitespace glyphs; mark FT_BitmapGlyph cast unsafe" \
  --body-file /home/mahi/repos/cantester_v/scripts/win_patches/pr1-vglyph-glyph-fixes.md
```

## Submission status

- **PR 1 (vglyph):** OPEN — https://github.com/vlang/vglyph/pull/4 (base `main`,
  1 file +5/−6, MERGEABLE). The two glyph bug fixes.
- **PR 4 (vglyph):** OPEN — https://github.com/vlang/vglyph/pull/5 (base `main`,
  5 files +12/−12, MERGEABLE). Restores `_check.vsh` to green. Verified: 0
  unused-param errors under `-N`, `v test .` 12/12, `v check-md .` clean.
- **PR 2 (gui titlebar):** not yet opened — branch `fix/windows-titlebar-before-sapp-run` ready.
- **PR 3 (gui gcc16):** not yet opened — branch `fix/windows-gcc16-compile` ready.

Plan (decided 2026-06-09): opened the two vglyph PRs (#4 bug fixes, #5 restore
verify-green) first. Next: watch them for maintainer response, then open PR 2 and
PR 3 to `vlang/gui` the same way (push both branches to one `MartenH/gui` fork).

**Env note:** `v up`'d to `ed17e5f` (2026-06-09) to verify against current V;
cantester still builds (gui@68b9302 ok), so no pin regression. `gh` 2.93 installed
at `~/.local/bin/gh`, authed as `MartenH`.
