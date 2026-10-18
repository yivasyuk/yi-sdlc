# Claude Code hooks

User-level hooks for Claude Code on Windows, checked out at `~/.claude/hooks` and registered in
`~/.claude/settings.json`:

| Hook | Event | What it does |
|---|---|---|
| `ask-dialog.ps1` | `PreToolUse` (matcher `AskUserQuestion`) | Answers Claude's questions in a desktop window (see the header of the script). |
| `notify.ps1` | `Notification`, `Stop`, `StopFailure` (async) | Shows a Windows toast. |

```json
"PreToolUse": [{ "matcher": "AskUserQuestion", "hooks": [{ "type": "command", "timeout": 86400,
  "command": "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File \"$HOME/.claude/hooks/ask-dialog.ps1\"" }] }],
"Notification": [{ "hooks": [{ "type": "command", "async": true,
  "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"$HOME/.claude/hooks/notify.ps1\" Notification" }] }]
```

`Stop` and `StopFailure` are registered like `Notification`, with the event name as the argument.
`ask-dialog.ps1` must stay UTF-8 with BOM: Windows PowerShell needs it to read the Ukrainian strings.
The hooks keep local state next to themselves (`notification-mode`, `all-recommended/`); git ignores it.
