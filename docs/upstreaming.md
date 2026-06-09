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
  `v fmt`-clean. **vglyph has no CI.**
  - Caveat: a *local* `v fmt -verify` on an old V (our 0.5.1 pin) reports ~98
    pre-existing "not vfmt'ed" files on pristine `main` too — that's vfmt
    version skew vs CI's check-latest V, NOT our changes. Verify deltas by
    diffing the flagged-file list against pristine `main`, not the raw count.
- **Flow:** neither account has org push, so it's the standard **fork → push
  branch → PR**. `gh` (authed as `MartenH`, scopes `repo`+`workflow`) does it.

## The PR set (3 PRs across 2 repos)

| PR | Repo | Branch (head) | Base | Commits | Body file |
|----|------|---------------|------|---------|-----------|
| 1 | `vlang/vglyph` | `fix/whitespace-glyph-empty-outline` | `main` | patch #04 + #05 | `scripts/win_patches/pr1-vglyph-glyph-fixes.md` |
| 2 | `vlang/gui` | `fix/windows-titlebar-before-sapp-run` | `main` | patch #03 | `scripts/win_patches/pr2-gui-titlebar.md` |
| 3 | `vlang/gui` | `fix/windows-gcc16-compile` | `main` | patch #01 + #02 | `scripts/win_patches/pr3-gui-gcc16.md` |

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

- **PR 1 (vglyph):** OPEN — https://github.com/vlang/vglyph/pull/4 (opened
  2026-06-09 by MartenH; base `main`, 1 file +5/−6, MERGEABLE). vglyph has no CI.
- **PR 2 (gui titlebar):** not yet opened — branch `fix/windows-titlebar-before-sapp-run` ready.
- **PR 3 (gui gcc16):** not yet opened — branch `fix/windows-gcc16-compile` ready.

Plan (decided 2026-06-09): **opened PR 1 first** to confirm it renders correctly
on GitHub (✅ title/body/diff all good). Next: watch PR 1 for maintainer
response, then open PR 2 and PR 3 to `vlang/gui` the same way (push both branches
to one `MartenH/gui` fork).
