---
name: git-commit
description: >-
  Format git commit messages, branch names, and PR titles the way Yaroslav's repos do (feature or ticket
  prefix, present tense, one logical change). Use when creating a branch, staging a commit, or opening a pull
  request.
---

# Git commits, branches and PRs

**Only commit or push when the user asks.** These rules are the one source for every repo; other skills
and docs point here instead of restating them. A repo changes them in one place only: its project profile
(`.claude/yi-sdlc/project.md`) § Commits, which may add its own prefixes (foundation work), name the
protected branch and its CI, and override a rule below. Where it does, the profile wins.

## Commit subject

```
<id>-<name>: <details>    work on a tracker ticket
<name>: <details>         no ticket ID
```

- `<name>` is the work's kebab-case slug: the feature's name as used in `docs/features/<slug>/` and
  `docs/roadmap.md` (e.g. `tickers-loader`), or the fix's or the change's name. It is the `{slug}` in the
  branch name.
- `<id>` is the tracker ticket's ID. With a ticket, the prefix is the branch name after its group:
  `feature/ts-12-details-panel` → `ts-12-details-panel:`, `fix/yv-1-fill-gaps-error` →
  `yv-1-fill-gaps-error:`, `change/yv-7-chart-enhancements` → `yv-7-chart-enhancements:` (profile
  § Branches; by default `fix/<id>-<slug>`, `change/<id>-<slug>`, `feature/<id>-<slug>`).
- A feature ticket with no name goes on its `feature-unnamed` branch (by default `feature/<id>`) and uses
  the ticket ID alone: `<id>: <details>`.
- Foundation work uses the prefix profile § Commits names (for example `survey:` / `scaffold:`).
- `<details>` says what changed in the present tense, capitalised, one logical change per commit.

Examples: `ts-12-details-panel: Add the Details panel sizing rules`, `tickers-loader: Add candle upsert`,
`yv-1-fill-gaps-error: Stop fill gaps from failing on an empty range`, `scaffold: Materialize the skeleton`.

Not this: `feat: …` (conventional-commit prefixes), `[tickers-loader] …`, `ts-12: …` on a named feature,
or a subject with no prefix.

## Body (optional)

For a non-trivial change, add a blank line and then a body wrapped at ~72 chars. Explain **what** and
**why**, not how. Mention migrations, contract changes (and regenerated clients) and follow-ups.

## Pull requests

- Title: same `<prefix>: <details>` form.
- Body: what changed and why, links to the feature's spec (`docs/features/<slug>/PRD.md` or `spec.md`,
  the ACs covered) and any ADRs, plus anything a reviewer needs (a migration, config or secret changes,
  follow-up work).

## Pre-commit check

- [ ] Subject is `<prefix>: <summary>`: `<id>-<name>`, `<name>`, `<id>` (unnamed ticket) or a foundation prefix
- [ ] Present tense, capitalised, one logical change
- [ ] Branch name matches profile § Branches, or `<group>/<name>` (`feature/`, `fix/`, `change/`, `scaffold/`, …)
