---
name: git-commit
description: >-
  Format git commit messages, branch names, and PR titles the way Yaroslav's repos do (feature or ticket
  prefix, present tense, one logical change). Use when creating a branch, staging a commit, or opening a pull
  request.
---

# Git commits, branches and PRs

**Only commit or push when the user asks.** When the repo has a project profile
(`.claude/yi-sdlc/project.md`), its § Commits adds the repo's own prefixes, the protected branch and its CI;
its conventions file (`AGENTS.md` or `CLAUDE.md`) wins over this skill where they differ.

## Commit subject

```
<feature-name>: <details>
```

- `<feature-name>` is the feature's slug as used in `docs/features/<slug>/` and `docs/roadmap.md`
  (kebab-case, e.g. `tickers-loader`). Foundation work uses the prefix profile § Commits names (for
  example `survey:` / `scaffold:`).
- `<details>` says what changed in the present tense, capitalised, one logical change per commit.
- Work on a YouTrack ticket uses the ticket ID instead: `<id>: <details>`, on a `fix/<id>-<slug>` branch
  (`/yi-sdlc:impl-fix`) or a `change/<id>-<slug>` branch (`/yi-sdlc:impl-change`).
- A feature ticket built with `/yi-sdlc:impl-feature` goes on `feature/<id>-<feature-name>` and keeps the
  `<feature-name>:` prefix; an unnamed one goes on `feature/<id>` and uses the ticket ID.

Examples: `tickers-loader: Add candle upsert`, `scaffold: Materialize the skeleton`,
`yv-1: Stop fill gaps from failing on an empty range`.

Not this: `feat: …` (conventional-commit prefixes), `[tickers-loader] …`, or a subject with no prefix.

## Body (optional)

For a non-trivial change, add a blank line and then a body wrapped at ~72 chars. Explain **what** and
**why**, not how. Mention migrations, contract changes (and regenerated clients) and follow-ups.

## Pull requests

- Title: same `<prefix>: <details>` form.
- Body: what changed and why, links to the feature's spec (`docs/features/<slug>/PRD.md` or `spec.md`,
  the ACs covered) and any ADRs, plus anything a reviewer needs (a migration, config or secret changes,
  follow-up work).

## Pre-commit check

- [ ] Subject is `<prefix>: <summary>` with a feature, foundation or ticket prefix
- [ ] Present tense, capitalised, one logical change
- [ ] Branch name matches `<group>/<name>` (`feature/`, `fix/`, `change/`, `scaffold/`, …)
