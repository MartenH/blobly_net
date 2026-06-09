Found while bringing up vlang/gui on native Windows, but it's a real ordering bug independent of toolchain (reproduces under both mingw-w64/gcc and MSVC).

`titlebar_dark()` calls `sapp.win32_get_hwnd()`, which asserts `_sapp.valid` and aborts if sokol_app hasn't been initialised yet:

```
titlebar_dark() -> win32_get_hwnd() -> abort on _sapp.valid
```

`set_theme()` (and any early dark/light toggle) can run **before** `sapp.run()`, so on Windows the app aborts at startup before the window even opens.

This guards the `DwmSetWindowAttribute` call with `sapp.isvalid()`, so an early call is a harmless no-op; once the window is up the titlebar attribute is applied exactly as before.

```v
pub fn titlebar_dark(dark bool) {
	$if windows {
		if sapp.isvalid() {
			C.DwmSetWindowAttribute(sapp.win32_get_hwnd(), 20, &dark, sizeof(dark))
		}
	}
}
```

`v fmt`-clean. Verified on native Windows (mingw-w64 and MSVC builds both start cleanly with the guard).
