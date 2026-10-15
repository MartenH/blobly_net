module assets

import os

// The generated constants ARE the PNGs in this directory, all of them: change or add a PNG and
// forget gen.vsh, and this fails rather than the app shipping the old picture.
fn test_the_constants_are_the_files() {
	here := os.dir(@FILE)
	pngs := os.glob(os.join_path(here, '*.png'))!
	assert pngs.len == files.len, 'a PNG has no constant (or a constant no PNG): v run gen.vsh'
	for p in pngs {
		name := os.file_name(p)
		assert name in files, '${name} has no constant: v run gen.vsh'
		assert files[name] == os.read_bytes(p)!, '${name} changed: v run gen.vsh'
	}
}
