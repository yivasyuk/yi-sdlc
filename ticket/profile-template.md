# Project profile for the yi-sdlc ticket skills

Copy this file to `.claude/yi-sdlc/project.md` in a repo to run `/yi-sdlc:impl-fix`, `/yi-sdlc:impl-change` and
`/yi-sdlc:impl-feature` there, and fill in every section. The skills and `workflow.md` point into it as
"profile § <section>", so keep the headings. Write facts the skills can act on (commands, paths, ports,
names), not advice.

## Tracker

- YouTrack project: `<key>` (<name>). Issue IDs: `<key>-<n>`.
- Normalize: `<KEY>-12` and a bare `12` to `<key>-12` (plus any old prefix the project had).
- Example IDs for the skills' questions: fix `<key>-12`, change `<key>-2`, feature `<key>-15`.

## Docs

- Conventions file: `AGENTS.md` (or `CLAUDE.md`).
- Architecture map and ADRs: `docs/architecture-map.md`, `docs/adr/`, `docs/features/<slug>/adr/`.
- Product docs the feature pipeline reads: `docs/roadmap.md`, `docs/idea-brief.md`.
- Feature names in use, as a style example: `<feature-a>`, `<feature-b>`.

## Environment

- Script: `<main>/.claude/yi-sdlc/ticket-env.ps1`, with the commands `workflow.md` § The isolated environment
  lists.
- The operator's dev stack, never touched: <ports, database, checkout>.
- What `up` gives the worktree: <its own database copy, app processes on free ports, …>. Worktrees go to
  `<path>\<id>`.
- The JSON `up` prints: <key → meaning, e.g. `api`, `web`, `apiJson` (the Api's JSON log)>.
- Outside reach: <live services the isolated app still calls, and what must never happen there (orders,
  real accounts, paid calls)>.

## Live check

How to see behaviour on the isolated app, for reproducing a bug and showing a change: <call the `api` URL with
`curl`; drive the `web` URL with a browser tool; read the logs at …>. After code changes: `ticket-env.ps1
api-restart -Issue <id>`.

## Test levels

| The behaviour lives in… | Test level | Where |
|---|---|---|
| <layer> | <unit / integration / e2e> | <test project or folder> |

Conventions a change follows: <skills to use, rules files, generated code to refresh after an endpoint change>.

## Docs sync

Rows to add to `workflow.md` § Docs sync for this repo, and the repo-wide docs the leftover sweep searches:

| The change touches… | Update |
|---|---|
| A convention or gotcha learned the hard way | `AGENTS.md` § Gotchas |

## Gates

```bash
<build and test>
<format / lint>
ticket-env.ps1 e2e -Issue <id>    # when <…> changed
```

Generated files the build rewrites, and which diffs in them are noise: <…>.

## Commits

- Feature commits use `<feature-name>:`; foundation work uses <`scaffold:` / …>.
- `main` is protected; merges are <squash>; CI: <workflows>.

## Manual testing

Needed only for: <what automated tests here can't cover>.

## Critical stops

Repo-specific additions to `workflow.md` § Critical stops in auto: <e.g. placing orders, touching real
accounts, granting an agent a new operation>.

## Change scope

- A change graduates to `/yi-sdlc:impl-feature` when it needs <a new module / capability folder, …>.
- Part of every change's acceptance criteria: <e.g. whether an AI agent may call a new operation>.

## Ship

What `/yi-sdlc:impl-feature` brings in line before its PR, beyond the feature docs: <repo-wide docs>.
