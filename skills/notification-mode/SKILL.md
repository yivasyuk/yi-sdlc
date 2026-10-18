---
name: notification-mode
description: Set where Claude's questions are asked - desktop (a window) or terminal. Persists across sessions.
disable-model-invocation: true
argument-hint: [desktop|terminal|toggle|status]
allowed-tools: PowerShell
---

Run this with the PowerShell tool, passing the argument through unchanged (use `status` when `$ARGUMENTS` is empty):

`& "${CLAUDE_PLUGIN_ROOT}/hooks/ask-dialog.ps1" -Mode <argument> -DataDir "${CLAUDE_PLUGIN_DATA}"`

Reply with the single status line it prints and nothing else.
