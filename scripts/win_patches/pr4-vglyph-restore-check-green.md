The verify workflow — `.agent/workflows/verify.md` → `v run _check.vsh` — runs the example checks with `v -check -N`, and `-N` promotes `unused parameter` **notices to hard errors**. On a current V there are 15 pre-existing unused-parameter sites, so `_check.vsh` fails on a clean checkout:

```
accessibility/backend_stub.v:8:49: error: unused parameter: `nodes`
...
glyph_atlas.v:369:2: error: unused parameter: `stroke_radius`
examples/showcase.v:643:48: error: unused parameter: `width`
```

This prefixes the genuinely-unused parameters with `_` (the V idiom for "intentionally unused"). **No behavioural change** — purely parameter renames:

- **`accessibility/backend_stub.v`** (9) — the stub backend is the no-op implementation selected on platforms without native accessibility, so every interface parameter is unused by design.
- **`accessibility/backend_linux.v`** (1) — only `cursor_line` is unused; `node_id`/`value`/`selected_range` still drive the atk calls.
- **`glyph_atlas.v`** (1) — `load_stroked_glyph`'s `stroke_radius` is unused (the stroke radius is configured on the `FT_Stroker`, not read here).
- **`examples/showcase.v`** (3) + **`examples/accessibility_check.v`** (1) — unused callback/section parameters.

After this change:
- `v -check -N examples/*.v` → **0** unused-parameter errors (was 11 under `-N`)
- `v test .` → **12/12 pass**
- `v check-md .` → clean

So `v run _check.vsh` goes green again on a current V.
