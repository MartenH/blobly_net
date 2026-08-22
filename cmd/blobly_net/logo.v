module main

import stbi
import vgui

// The BLOBLY.NET wordmark, white on transparent, sized for the menu bar (drawn at font
// height; the PNG is 2x that for a clean minify). White so one texture serves both themes:
// menu_image multiplies by a tint, and white times the tint IS the tint.
const logo_png = $embed_file('logo_white.png')

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
