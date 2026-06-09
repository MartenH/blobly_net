Two small fixes found while bringing up vglyph on a native-Windows build (mingw-w64 / gcc 16), but neither is Windows-specific.

### 1. Don't panic on whitespace glyphs with empty outlines
Whitespace glyphs such as `U+0020 SPACE` legitimately load with an empty outline (`n_points == 0`). In the subpixel-shift path, `load_glyph()` panicked on this in debug builds:

```
FT_Outline_Translate requires loaded outline, got empty. Check FT_Load_Glyph flags.
```

So any text containing a space aborts a debug build. `FT_Outline_Translate` on an empty outline is a no-op anyway, so this guards the translate on `n_points > 0` and drops the panic. Release builds already called `FT_Outline_Translate` unconditionally; this just makes the empty case explicit and removes the debug-only abort.

### 2. Wrap the `FT_BitmapGlyphRec` pointer cast in `unsafe`
`load_stroked_glyph()` casts `&C.FT_GlyphRec` → `&C.FT_BitmapGlyphRec`, a pointer-type cast that V warns about outside an `unsafe` block. Wrapped in `unsafe {}` to make the intent explicit and silence the warning, consistent with the other C-interop pointer casts in the module.

Both changes are `v fmt`-clean. Verified by building a vglyph-based GUI app on both Linux and native Windows.
