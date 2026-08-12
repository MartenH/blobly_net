# Blobly Net — project guide for coding agents

**The guide is [`CLAUDE.md`](CLAUDE.md). Read that file.**

This one is a real file rather than a symlink on purpose. Two agents look for two names —
Claude Code reads `CLAUDE.md` and nothing else, Codex and others read `AGENTS.md` — and a
symlink either way round becomes a 9-byte text file on a checkout without symlink support
(Windows without Developer Mode, `core.symlinks=false`), so whichever tool reads the link
silently gets a one-word guide. A pointer survives that: readable everywhere, and it names
where to go.

Edit `CLAUDE.md`. Nothing here should ever grow beyond this pointer.
