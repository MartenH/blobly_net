# Contributing

**Issues and pull requests are both welcome.** Fork the repo, branch from `main`, open a PR.

This is a young project with one maintainer, so it runs the way most public repositories do:

- **CI does not start until the maintainer approves the run.** That is GitHub's own gate for
  workflows from a fork, not a judgement on your patch — expect a short wait on a first PR.
- **The maintainer merges, by rebase.** `main` is the only long-lived branch. An outside PR is
  merged with "Rebase and merge", so **the commits you push are the commits that land** — keep
  them tidy (squash your own fixups before review), and each one is checked as below. This is
  deliberate: a squash-merge would be authored by GitHub from your account's email, which the
  identity check cannot see before the merge exists.
- **An automated review runs first.** The maintainer requests a Codex review on the PR; it
  posts findings inline, and you may be asked to address them before the human review.
- **Talk before a large change.** [Open an issue](../../issues) for anything beyond a fix, so
  the direction is agreed before the work is done. See [CLAUDE.md](CLAUDE.md) for the
  architecture rule (every module GUI-free and unit-tested) and the build.

## Commit identity

Every commit must be **authored** by your **GitHub noreply address** —
`<id>+<login>@users.noreply.github.com`, which github.com → Settings → Emails shows you.
Set it for this repo only:

```sh
git config user.email <id>+<login>@users.noreply.github.com
```

This is checked by CI ([`.github/workflows/guard.yml`](.github/workflows/guard.yml)) on the PR
and again when it lands, and it is enforced rather than trusted because a work address once
reached this history and had to be rewritten out of every commit. The noreply form can never be
one, and it still names you. (The maintainer's own personal address is the one exception.)

## Commit messages

The same rule applies to what a message **says**: a message body may not contain an email
address other than the allowed authors or a bot trailer (`Co-Authored-By: … <noreply@anthropic.com>`).
Describe an address instead — "rejects a non-maintainer work address". A message is permanent:
it survives branch deletion, and removing one costs a rewrite of every branch that carries it.
The **PR title** is held to the same rule, so that it is safe as a squash subject too.

To catch both before they reach CI, install the local hooks:

```sh
git config core.hooksPath .githooks
```
