module main

import stbi
import vgui

// The BLOBLY.NET wordmark, white on transparent, sized for the menu bar (drawn at font
// height; the PNG is 2x that for a clean minify). White so one texture serves both themes:
// menu_image multiplies by a tint, and white times the tint IS the tint.
const logo_png = $embed_file('logo_white.png')

// The window/taskbar icon: the wordmark's stencil B on the accent-blue rounded tile, 64px
// (the wordmark itself is far too wide for a square icon). Decoded and downscaled at startup
// so the OS gets native 16/32/48/64 candidates instead of scaling one bitmap.
const icon_png = $embed_file('icon_b.png')

// set_app_icon decodes the embedded icon and hands the OS a size set. Call after vgui.init().
// If decoding fails it falls back to the procedural placeholder, so the window never goes
// without an icon.
fn set_app_icon() {
	img := stbi.load_from_memory(icon_png.data(), icon_png.len) or {
		vgui.set_window_icon(32, 32, app_icon())
		return
	}
	defer {
		img.free()
	}
	mut icons := []vgui.IconImage{}
	base := unsafe { icon_rgba_copy(img.data, img.width, img.height) }
	icons << vgui.IconImage{img.width, img.height, base}
	for sz in [48, 32, 16] {
		small := stbi.resize_uint8(img, sz, sz) or { continue }
		icons << vgui.IconImage{sz, sz, unsafe { icon_rgba_copy(small.data, sz, sz) }}
		small.free()
	}
	vgui.set_window_icons(icons)
}

// icon_rgba_copy clones a decoded w×h RGBA buffer into a V-owned []u8, which is what the
// vgui icon/texture API takes. (Lifetime is not the reason: GLFW copies the pixels before
// glfwSetWindowIcon returns.)
@[unsafe]
fn icon_rgba_copy(data &u8, w int, h int) []u8 {
	mut out := []u8{len: w * h * 4}
	unsafe { vmemcpy(out.data, data, out.len) }
	return out
}

// load_logo decodes the embedded wordmark and uploads it as a GL texture. Call after
// vgui.init(). Failure just leaves logo_tex 0 and the menu bar starts at File, as before.
fn (mut app App) load_logo() {
	img := stbi.load_from_memory(logo_png.data(), logo_png.len) or { return }
	defer {
		img.free()
	}
	mut rgba := []u8{len: img.width * img.height * 4}
	unsafe { vmemcpy(rgba.data, img.data, rgba.len) }
	app.logo_tex = vgui.create_texture(img.width, img.height, rgba)
	app.logo_aspect = f32(img.width) / f32(img.height)
}

// draw_logo puts the wordmark at the left end of the menu bar; menu_image inks it with the
// theme's text color, so there is no theme branch to keep in sync here.
fn draw_logo(app &App) {
	if app.logo_tex == 0 {
		return
	}
	vgui.menu_image(app.logo_tex, app.logo_aspect)
}
