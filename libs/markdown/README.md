# Vendored vlang/markdown (md4c)

Upstream [vlang/markdown](https://github.com/vlang/markdown) at commit **`ef2f101`** — the
V binding plus the [md4c](https://github.com/mity/md4c) C parser it wraps — committed here
and compiled into the binary, so a fresh box builds from git alone (the repo's
single-source-of-truth principle).

It has exactly one caller: `markdown.to_html()` in `cmd/blobly_net/help.v`, which renders the
Help pages to HTML for the "Open in browser" view.

## Why vendored rather than fetched

That one call used to cost a `git clone` into `$VMODULES` in **four** places —
`scripts/setup_env.sh`, `ci.yml`, `windows.yml` and `release.yml` — with the pin `ef2f101`
written out in each. Windows had no installer outside CI at all, so a local Windows build
failed on `cannot import module "markdown"` while CI stayed green. Vendoring deletes all four
steps, states the version once (here, in git), and takes a network fetch out of the build.

`libs` is already on V's `-path` for the `vgui` binding, so `import markdown` resolves with no
flag changes. Its `v.mod` makes `@VMODROOT` in `md4c.v` point at this directory, so the
`thirdparty/md4c` include path and the `md4c-lib.o` flag stay correct; V builds that object
from its sibling `md4c-lib.c` on first compile (gitignored, as upstream has it).

Licensed **MIT** — md4c © Martin Mitáš, the V bindings © Ned Palacios and the V project; the
full text is in [`LICENSE`](LICENSE) beside this file, unmodified.

## What's here vs. upstream

- All module sources (`html.v`, `html_experimental.v`, `md4c.v`, `plaintext.v`, `renderer.v`),
  `v.mod`, `LICENSE`, `.gitignore`, `.gitattributes` and the whole `thirdparty/` tree —
  unmodified. Keep the `.gitattributes`: its `eol=lf` is what stops a Windows checkout
  rewriting this vendored tree to CRLF, which would make every future upgrade diff as a
  whole-file change.
- **Dropped:** `*_test.v` (upstream's own tests — we do not run another project's suite in our
  CI), `.github/`, and `.editorconfig`. Re-fetch upstream to run them.
- **Added:** this README (upstream's own was dropped in its place).

## Upgrading

Clone upstream at the new commit, copy the files listed above over this directory, delete the
dropped ones, and record the new commit at the top of this file. Then rebuild and open Help →
"Open in browser" to confirm the pages still render.
