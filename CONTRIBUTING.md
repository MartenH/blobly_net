# Contributing

**Issues and pull requests are both welcome.** Fork the repo, branch from `main`, open a PR.

This is a young project with one maintainer, so it runs the way most public repositories do:

- **CI does not start until the maintainer approves the run.** That is GitHub's own gate for
  workflows from a fork, not a judgement on your patch — expect a short wait on a first PR.
- **The maintainer merges, by squash.** `main` is the only long-lived branch; every change
  reaches it as one squash commit of a reviewed PR, so a PR is one topic and its description
  says what and why. The squash subject is your commit's title for a one-commit PR, and the PR
  title otherwise — so write the one that will be used.
- **An automated review runs first.** The maintainer requests a Codex review on the PR; it
  posts findings inline, and you may be asked to address them before the human review.
- **Talk before a large change.** [Open an issue](../../issues) for anything beyond a fix, so
  the direction is agreed before the work is done. See [CLAUDE.md](CLAUDE.md) for the
  architecture rule (every module GUI-free and unit-tested) and the build.

Commit under whatever name and address you normally use.
