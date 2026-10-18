---
name: wt
description: Alias of /yi-sdlc:worktree. Create (or reuse) a git worktree for a branch (default - the current branch), copy gitignored files and Claude memory, and open Rider.
disable-model-invocation: true
argument-hint: [branch-name] [-BaseBranch master] [-RepoPath <path>]
allowed-tools: PowerShell, Bash
---

This is a shortcut for the `/yi-sdlc:worktree` skill. Follow the instructions in
`${CLAUDE_PLUGIN_ROOT}/skills/worktree/SKILL.md` (read it first) with the arguments: `$ARGUMENTS`

In short: run `& "${CLAUDE_PLUGIN_ROOT}/scripts/worktree.ps1" $ARGUMENTS` with the PowerShell tool, pass the arguments through
unchanged, do not `cd` into the worktree, and report the worktree path, branch source, whether the main clone was
switched to master, files copied, and any warning.
