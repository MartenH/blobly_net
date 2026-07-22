# Contributing

**Issues: yes, please. Pull requests: not yet.**

This project is still in its **design phase** — the architecture, the config format and the
wire formats are all still moving, so a patch written against today's code is likely to be
overtaken before it can land. That is the reason for the policy, not a lack of interest.

So: bug reports, questions and feature ideas are genuinely welcome —
[open an issue](../../issues). Pull requests are closed automatically, including ones that
would otherwise be fine; please don't spend the effort on a patch yet. If an issue needs a
code change, the maintainer makes it.

This will be revisited once the design settles. `main` is the only long-lived branch, and
only the maintainer can merge to it.

## Commit identity

Commits on `main` must be authored by **marten.hildell@gmail.com**. Anything else — in
particular a work address — is rejected by CI (`.github/workflows/guard.yml`). This is
enforced rather than trusted because the wrong address has ended up in this history before
and had to be rewritten out of every commit.

To set it locally for this repo only:

```sh
git config user.email marten.hildell@gmail.com
git config user.name  "Marten Hildell"
```

To catch it before it reaches CI, install the local hook:

```sh
git config core.hooksPath .githooks
```
