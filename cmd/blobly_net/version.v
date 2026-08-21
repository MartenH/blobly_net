module main

// app_version is the SINGLE statement of what this build calls itself — the window title and
// `--version` read it, and release.yml refuses a tag that disagrees, so the tag and what the
// binary reports can never drift. It is a COMMITTED constant, not a build-time injection: a
// release is "tag the commit whose const says so" (`git tag v0.1.0 && git push origin
// v0.1.0`), which keeps the version diffable and the build reproducible from any checkout.
// Bump it in the PR that prepares the next release, not before.
pub const app_version = '0.1.0'
