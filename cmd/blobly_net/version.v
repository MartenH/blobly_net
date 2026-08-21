module main

import v.vmod

// app_version is what this build calls itself — the window title and `--version` read it.
// The VALUE lives in v.mod, the repo's one version statement (self-review: this file first
// carried its own literal, and v.mod sat two lines of prose away saying 0.0.1); this const
// decodes the compile-time-embedded @VMOD_FILE at startup, so the two cannot disagree.
// release.yml's guard refuses a tag that does not match v.mod, and the release build then
// asserts the BINARY answers with the tag — bump v.mod in the PR that prepares a release.
pub const app_version = (vmod.decode(@VMOD_FILE) or { panic('v.mod unparsable: ${err}') }).version
