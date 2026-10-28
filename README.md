# yi-sdlc

Yaroslav's user-level Claude Code kit for Windows, packaged as a plugin. The repo is also its own marketplace
(`yi-plugins`), so it installs with one `marketplace add`.

| Part | Path | What it does |
|---|---|---|
| Hook `PreToolUse` (`AskUserQuestion`) | `hooks/ask-dialog.ps1` | Answers Claude's questions in one desktop window shared by every session: a tab per question call titled project · feature (a tab not opened yet is highlighted), recommended answers preselected, references, a word's Ukrainian translation on double-click-and-hold, a message field with pasted images, Ukrainian and British flags that set the language Claude writes in for the rest of a session, and Keep Recommended for the rest of a session, kept across `/clear`: it also tells Claude to work in auto mode, and only questions headed `Critical` are still asked. See the script's header. |
| Hook `SessionStart` | `hooks/ask-dialog.ps1 -SessionStart` | Records each session per Claude process, and on a `/clear` copies the cleared session's Keep Recommended and flag language to the new session id, so gate runs that clear after every gate keep them. A session that has them is told so at its start, so `implement-feature` resumes in auto mode and in that language. |
| Hooks `Notification`, `Stop`, `StopFailure` | `hooks/notify.ps1` | Shows a Windows toast (async). |
| Hook `SessionStart` | `hooks/language.ps1` | Sets the language every yi-sdlc skill writes in (questions, documents, tracker comments, PRs): `- Language: <name>` in § Language of the repo's `.claude/yi-sdlc/project.md` (the main clone's from a worktree), English by default. It overrides the imported skills' Ukrainian without editing them, so a sync keeps it. |
| Skills `/yi-sdlc:map-architecture` … `/yi-sdlc:ship-feature`, agents `yi-sdlc:critic`, `yi-sdlc:reviewer`, … | `skills/` (as listed in `sdlc-upstream.json`), `agents/`, `SDLC.md` | The SDLC pipeline from the [sdlc plugin](https://github.com/genkovich/sdlc) by Kyrylo Genkov (MIT, `LICENSE-sdlc`): 21 skills from ideation (`interview`, `write-prd`) through architecture, data model, API contract, tasks and TDD implementation to review and ship, plus 11 agents. Imported unchanged except for the namespace; `SDLC.md` is its README. |
| Command `notification-mode` | `scripts/notification-mode.cmd` | `desktop`, `terminal`, `toggle` or `status` (the default): where Claude's questions are asked. Runs in any terminal and leaves the Claude session alone: the hook reads the mode on every question, so a running session follows it from its next one. |
| Skills `/yi-sdlc:implement-fix`, `/yi-sdlc:implement-change`, `/yi-sdlc:implement-feature` | `skills/implement-{fix,change,feature}`, `ticket/` | Take a tracker ticket (defect, one-PR change, or feature through the full `yi-sdlc:*` pipeline) to a merged PR in an isolated environment: its own Pane (worktree and branch), with the repo's `ticket-env.ps1` around it. Run outside that Pane, a skill opens it and hands the run to a Claude agent there; `implement-feature` also adds a `gates` tab that clears the session after each approved gate (with Keep Recommended ticked, the session approves the gates itself and stops only for a critical finding). See [The ticket kit](#the-ticket-kit). |
| Skills `/yi-sdlc:create-tickets`, `/yi-sdlc:process-tickets` | `skills/create-tickets`, `skills/process-tickets` | The board around the ticket kit, YouTrack only. `create-tickets` files the open steps of `docs/roadmap.md` as tickets (Epic, Feature or Task by size, linked parent/subtask and depends-on by the roadmap's graph) and writes the links back into the roadmap. `process-tickets` ranks the ready tickets (features first, then tasks of features already running), asks which to start and confirms the exact set and count before anything starts (`--auto [N]` picks the top N itself, default 1, without asking), and starts each: a feature by giving the operator its `implement-feature` command (default depth `medium`), which opens the feature's own Pane, a task as a tab in its feature's Pane. Both read the profile's § Tracker and need `YOUTRACK_TOKEN`. |
| Skill `/yi-sdlc:run-application` | `skills/run-application` | Starts the app (backend, frontend, the rest) from the main clone or any worktree, each on its own ports so parallel sessions run side by side, and answers with checked links. Drives the repo's `.claude/yi-sdlc/run-app.ps1` (`up`, `status`, `restart`, `down`, `list`; the interface: `run-script.md`), and writes one from the bundled template when the repo has none. |
| Skill `/yi-sdlc:complete` | `skills/complete` | Lands the work in one command: finds every change in the working tree (or only this session's with `--session`), splits it into logical changes and gives each its own branch, commit and PR, then squash-merges each once its builds pass (or right away when the repo has no CI). `--one-pr` puts everything into a single PR instead. Takes an optional free-text prompt to steer the run (what to include, how to group it, commit and PR wording). Operator-only. |
| Skill `yi-sdlc:git-commit` | `skills/git-commit` | Commit, branch and PR title conventions (feature or ticket prefix). Model-invoked. |
| Status line | `statusline/statusline.js` | Model, effort, context, branch, 5h/7d limits, cache hit ratio and cost. A plugin can't register a status line, so `~/.claude/settings.json` points at this file (below). |

Hook registrations live in `hooks/hooks.json`. The dialog keeps its state (`notification-mode`, `keep-recommended\`)
in the plugin's data dir, `~/.claude/plugins/data/<plugin id>/`, which survives plugin updates.

## Install

The working copy is the plugin: a marketplace added from a local path loads the plugin in place, so edits here take
effect in the next session without reinstalling.

```powershell
git clone https://github.com/yivasyuk/yi-sdlc C:\Projects\Pet\yi-sdlc
claude plugin marketplace add C:\Projects\Pet\yi-sdlc
claude plugin install yi-sdlc@yi-plugins
```

Put `C:\Projects\Pet\yi-sdlc\scripts` on the user `PATH` to run `notification-mode` from any terminal.

Then in `~/.claude/settings.json`:

- remove any `hooks` entries for `ask-dialog.ps1` or `notify.ps1`, or every question opens two dialogs;
- point the status line at the repo:

```json
"statusLine": { "type": "command", "command": "node \"C:/Projects/Pet/yi-sdlc/statusline/statusline.js\"", "padding": 0, "refreshInterval": 10 }
```

## The ticket kit

Everything generic about ticket work lives in `ticket/`; what is particular to a repo lives in that repo's
`.claude/yi-sdlc/`.

| Plugin (`ticket/`) | What it holds |
|---|---|
| `workflow.md` | The flow `implement-fix`, `implement-change` and `implement-feature` share: SDLC mode, branches, test levels, docs sync, gates, review, PR, merge, ticket comments, the Blocked exit |
| `tracker/contract.md` | The abstract tracker: column roles (`in-progress`, `blocked`, `merged`, and optionally `in-review` and `test`), which tickets can be taken and which moves the agent makes (forward along the board's order, or to `blocked`), how `sdlc-mode` is read (default `developer`), the `manual-qa` label, and the `tracker.<operation>`s |
| `tracker/youtrack.md`, `tracker/jira.md` | Adapters: setting up the tracker's MCP server (YouTrack MCP; Atlassian Rovo MCP, v2 and v1) and which of its tools carries out each operation |
| `environment.md` | The interface a repo's isolated environment script implements (`up -Worktree <the ticket's Pane worktree>`, `status`, `restart`, `down`); the plugin has no environment code |
| `profile-template.md` | The template for a repo's profile |

| Repo (`.claude/yi-sdlc/`) | What it holds |
|---|---|
| `project.md` | The profile: the language the skills write in (default English), the tracker mapping (adapter, MCP server, account, the board's columns in order with their roles, where `sdlc-mode` lives: a field and/or tags), branch patterns, the environment, live checks, test levels, gates, docs to keep in sync |
| `ticket-env.ps1` | The repo's own isolated environment |
| `run-app.ps1` | Optional: how `/yi-sdlc:run-application` starts the app from any checkout |

The repo also registers its tracker's MCP server in `.mcp.json`.

## The imported sdlc plugin

`scripts/sync-sdlc.ps1` imports the upstream plugin from its public repo,
[genkovich/sdlc](https://github.com/genkovich/sdlc): it clones `-Ref` (default `main`; a commit pins it) into a
temp folder, or takes a local checkout with `-Source`, which it never writes to. It copies the skills to `skills/`, the agents to `agents/`, the tests to `tests/sdlc/`, the README to `SDLC.md`
and the licence to `LICENSE-sdlc`, then rewrites the copies' references: `sdlc:<name>` → `yi-sdlc:<name>` and
`/sdlc-<name>` → `/yi-sdlc:<name>`. The settings file name `.claude/sdlc.local.md` stays, so repos keep theirs.
`sdlc-upstream.json` records the repo, ref, commit and version and what was imported; a re-run replaces exactly that,
so don't edit the imported files here (the next sync overwrites them) and keep yi-sdlc's own skills under names
upstream doesn't use (the script stops on a collision).

To pick up an upstream release, run the script, review the diff and commit it as
`scaffold: Sync sdlc <version>`. Keep `sdlc@local-plugins` disabled, or every skill shows up twice.

## Checks

```powershell
claude plugin validate C:\Projects\Pet\yi-sdlc
```

`hooks/ask-dialog.ps1` must stay UTF-8 with BOM: Windows PowerShell needs it to read its Ukrainian
strings. `ask-dialog.ps1 -Auto submit|close` builds the dialog in its own process without showing it; the
header lists the `ASK_DIALOG_*` variables for screenshots and extra tabs. The shared
window runs as its own process (`-Serve`, started by the first question, gone 5 minutes after its last
tab) and logs its failures to `ask-dialog.log` in the plugin's data dir.
