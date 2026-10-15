module assets

import os

// The generated constants ARE the PNGs: change a PNG and forget gen.vsh, and this fails rather
// than the app shipping the old picture.
fn test_the_constants_are_the_files() {
	here := os.dir(@FILE)
	assert logo_png == os.read_bytes(os.join_path(here, 'logo_white.png'))!, 'logo_white.png changed: v run gen.vsh'
	assert icon_png == os.read_bytes(os.join_path(here, 'icon_b.png'))!, 'icon_b.png changed: v run gen.vsh'
}

// And they are PNGs, so a generator that mangled the bytes cannot pass on lengths alone.
fn test_they_are_pngs() {
	sig := [u8(0x89), `P`, `N`, `G`, 0x0d, 0x0a, 0x1a, 0x0a]
	assert logo_png[..8] == sig
	assert icon_png[..8] == sig
}
