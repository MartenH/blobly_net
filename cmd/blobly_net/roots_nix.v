module main

// fs_roots is what the picker lists at the level above a drive root (pickrule.drives). There is
// no such level here — `/` is its own parent and pickrule.parent never returns the drives value
// on this platform — so this exists to give the Windows file its cross-platform twin (the pair
// must offer the same symbols; CLAUDE.md, "type-check the OTHER platform"), and lists the one
// root if the view is ever reached.
// drive_roots: one root here, `/` (pickrule.parent's `windows`).
const drive_roots = false

fn fs_roots() []string {
	return ['/']
}

// wsl_roots: WSL is reached from Windows; here there is nothing to list.
fn wsl_roots() []string {
	return []
}
