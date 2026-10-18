# Project profile for the yi-sdlc ticket skills

Copy this file to `.claude/yi-sdlc/project.md` in a repo to run `/yi-sdlc:impl-fix`, `/yi-sdlc:impl-change` and
`/yi-sdlc:impl-feature` there, and fill in every section. The skills, `workflow.md` and the files next to
it point into it as "profile § <section>", so keep the headings. Write facts the skills can act on
(commands, paths, ports, names), not advice.

The plugin holds everything tracker- and IDE-generic (the tracker contract and its YouTrack and Jira
adapters, the workflow, the launcher). This file holds only what is particular to the repo, and the
environment script next to it is the repo's own.

## Tracker

Maps the repo's tracker onto `tracker/contract.md`. The adapter (`youtrack` or `jira`) says how each
operation is carried out; here go the names.

```yaml
adapter: youtrack                     # youtrack | jira | a repo file with the same shape, e.g. .claude/yi-sdlc/tracker-adapter.md
mcp_server: youtrack                  # the server's name in .mcp.json (or the connector's)
account: <agent-login>                # what the MCP server is logged in as; the operator's actions use another account
ticket_url: https://<instance>/issue/{id}
# cloud_id: https://<site>.atlassian.net   # jira only
id_pattern: '^<key>-\d+$'
examples: { fix: <key>-12, change: <key>-2, feature: <key>-15 }

# The Agile board's columns, left to right. Give a role to the ones the skills need:
# in-progress, in-review, done and blocked (required), test (optional). The agent only moves a ticket
# forward along this order, or to blocked; it takes tickets from any column before in-review, and from blocked.
column_field: Stage                   # youtrack only: the state-type field the board is built on
columns:
  - Backlog
  - Ready To Start
  - { name: In Progress, role: in-progress }
  - { name: Blocked,     role: blocked }
  - { name: In Review,   role: in-review }
  - { name: Test,        role: test }
  - { name: Done,        role: done }

# Where a ticket carries its sdlc-mode: a field, tags (labels in Jira), or both (the field wins).
# Nothing set, or a value or tag not listed here: developer.
sdlc_mode:
  field: { name: sdlc-mode, values: { auto: auto, semi-auto: semi-auto, developer: developer } }
  # tags: { sdlc-auto: auto, sdlc-semi-auto: semi-auto }

# Optional: the tracker's issue types as hints for which skill owns a ticket.
type: { fix: [Bug, Exception], change: [Task, Usability Problem], feature: [Feature, Epic] }

labels: { manual-qa: manual-qa }      # the existing tag or label for each contract label
```

- Normalize: `<KEY>-12` and a bare `12` to `<key>-12` (plus any old prefix the project had).
- Take conditions: <optional, in prose, e.g. "only from Ready To Start", "never tickets tagged `hold`";
  leave out when none>.

## Branches

`{id}` is the normalized ticket ID, `{slug}` a short kebab-case summary (for a feature, its slug). Leave the
section out to get these defaults.

```yaml
base: main
fix: fix/{id}-{slug}
change: change/{id}-{slug}
feature: feature/{id}-{slug}
feature-unnamed: feature/{id}
```

## Docs

- Conventions file: `AGENTS.md` (or `CLAUDE.md`).
- Architecture map and ADRs: `docs/architecture-map.md`, `docs/adr/`, `docs/features/<slug>/adr/`.
- Product docs the feature pipeline reads: `docs/roadmap.md`, `docs/idea-brief.md`.
- Feature names in use, as a style example: `<feature-a>`, `<feature-b>`.

## Environment

The repo's own script, implementing `environment.md` (the plugin has no environment code).

- Script: `<main>/.claude/yi-sdlc/ticket-env.ps1`, with `up`, `status`, `restart` and `down`.
- More commands: <e.g. `e2e -Issue <id>`: the end-to-end tests against the isolated environment; leave out
  when none>.
- The operator's dev stack, never touched: <ports, database, checkout>.
- What `up` gives the worktree: <its own database copy, app processes on free ports, …>. Worktrees go to
  `<path>\<id>`. What `restart` does: <rebuilds and restarts …, applies migrations>.
- The JSON `up` prints: <key → meaning, e.g. `api`, `web`, `apiJson` (the Api's JSON log)>.
- Outside reach: <live services the isolated app still calls, and what must never happen there (orders,
  real accounts, paid calls)>.

## Launcher

Optional: without this section, each ticket tries its own Rider tab and falls back to the invoking session
(`launcher.md`).

- Launcher: `rider` (or `here`: every ticket runs in the session that invoked the skill).
- Setup: <PowerShell run in the tab before Claude starts, e.g. `$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'`;
  leave out when none>.
- Claude arguments: <extra `claude` flags for the tab session, e.g. `--permission-mode auto`; leave out when
  none>.

## Live check

How to see behaviour on the isolated app, for reproducing a bug and showing a change: <call the `api` URL with
`curl`; drive the `web` URL with a browser tool; read the logs at …>. After code changes: `ticket-env.ps1
restart -Issue <id>`.

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
- `<base>` is protected; merges are <squash>; CI: <workflows>.

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
