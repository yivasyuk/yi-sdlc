# yi-sdlc

Yaroslav's user-level Claude Code kit for Windows, packaged as a plugin. The repo is also its own marketplace
(`yi-plugins`), so it installs with one `marketplace add`.

| Part | Path | What it does |
|---|---|---|
| Hook `PreToolUse` (`AskUserQuestion`) | `hooks/ask-dialog.ps1` | Answers Claude's questions in a desktop window: recommended answers preselected, UA/GB translation, references, a message field with pasted images, and All As Recommended for the rest of a session. See the script's header. |
| Hooks `Notification`, `Stop`, `StopFailure` | `hooks/notify.ps1` | Shows a Windows toast (async). |
| Skill `/yi-sdlc:notification-mode` | `skills/notification-mode` | `desktop`, `terminal`, `toggle` or `status`: where Claude's questions are asked. |
| Skills `/yi-sdlc:impl-fix`, `/yi-sdlc:impl-change`, `/yi-sdlc:impl-feature` | `skills/impl-*`, `ticket/workflow.md`, `scripts/rider-tab.ps1` | Take a YouTrack ticket (defect, one-PR change, or feature through the full `sdlc:*` pipeline) to a merged PR in an isolated environment. Each ticket runs in its own Claude session in a Rider terminal tab named after its branch or feature, so several can run in parallel (through the `rider` MCP server; without it, in the invoking session). The shared flow is `ticket/workflow.md`; each repo supplies a profile, `.claude/yi-sdlc/project.md` (template: `ticket/profile-template.md`), with its tracker project, environment script, gates, test levels and docs to keep in sync. Need the `sdlc` plugin and the `youtrack` MCP server. |
| Skill `yi-sdlc:git-commit` | `skills/git-commit` | Commit, branch and PR title conventions (feature or ticket prefix). Model-invoked. |
| Status line | `statusline/statusline.js` | Model, effort, context, branch, 5h/7d limits, cache hit ratio and cost. A plugin can't register a status line, so `~/.claude/settings.json` points at this file (below). |

Hook registrations live in `hooks/hooks.json`. The dialog keeps its state (`notification-mode`, `all-recommended\`)
in the plugin's data dir, `~/.claude/plugins/data/<plugin id>/`, which survives plugin updates.

## Install

The working copy is the plugin: a marketplace added from a local path loads the plugin in place, so edits here take
effect in the next session without reinstalling.

It depends on the `sdlc` plugin from the `local-plugins` marketplace (`dependencies` in `plugin.json`, allowed by
`allowCrossMarketplaceDependenciesOn` in `marketplace.json`). Add that marketplace first; installing `yi-sdlc` then
installs `sdlc` too, and `yi-sdlc` stays disabled while `sdlc` is disabled or missing.

```powershell
git clone https://github.com/yivasyuk/yi-sdlc C:\Projects\Pet\yi-sdlc
claude plugin marketplace add C:\Projects\Pet\yi-sdlc
claude plugin install yi-sdlc@yi-plugins
```

Then in `~/.claude/settings.json`:

- remove any `hooks` entries for `ask-dialog.ps1` or `notify.ps1`, or every question opens two dialogs;
- point the status line at the repo:

```json
"statusLine": { "type": "command", "command": "node \"C:/Projects/Pet/yi-sdlc/statusline/statusline.js\"", "padding": 0, "refreshInterval": 10 }
```

## Checks

```powershell
claude plugin validate C:\Projects\Pet\yi-sdlc
```

`hooks/ask-dialog.ps1` must stay UTF-8 with BOM: Windows PowerShell needs it to read its Ukrainian
strings. `ask-dialog.ps1 -Auto submit|close` builds the dialog without showing it; the header lists the
`ASK_DIALOG_*` variables for screenshots and translation checks.
