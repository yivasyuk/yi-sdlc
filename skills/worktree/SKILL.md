---
name: worktree
description: Create (or reuse) a git worktree for a branch, copy gitignored/local files and Claude memory, and open the solution in Rider. With no branch, uses the current branch (main clone is moved to master only if it is on that branch). Use when the user wants to work on a branch in parallel in a separate Rider window / Claude session.
disable-model-invocation: true
argument-hint: [branch-name] [-BaseBranch master] [-RepoPath <path>]
allowed-tools: PowerShell, Bash
---

Run the plugin's script `${CLAUDE_PLUGIN_ROOT}/scripts/worktree.ps1` with the arguments: `$ARGUMENTS`

Steps:
1. The branch name is optional. If omitted, the script uses the main clone's current branch. The script checks out
   master in the main clone only when the main clone is on the worktree branch; otherwise it leaves it untouched.
   It never commits. This is intended; do not ask for a name.
2. Default `-RepoPath` is the main clone `C:\Work\Repo\EvenFlow-Backend`. If the current repo is a different one,
   pass `-RepoPath <main clone root>`, `-SolutionName <its .sln>` and a suitable `-WorktreeRoot`.
3. Run with the PowerShell tool: `& "${CLAUDE_PLUGIN_ROOT}/scripts/worktree.ps1" [branch] [extra args]`. Pass the user's
   arguments through unchanged.
4. The script only opens Rider on the worktree; it does not start any Claude session or terminal. This current
   session keeps running in the old folder; do not `cd` into the worktree.
5. Report briefly: worktree path, branch source (existing/remote/new/current), whether the main clone was switched to master, files
   copied, and any warning. If it fails, show the error; do not retry blindly.

Notes:
- Branch resolution order: existing local branch, else a branch that exists on `origin` (verified with
  `git ls-remote`, fetched and checked out tracking it), else a new branch from `-BaseBranch`.
- A branch can be checked out in only one worktree; the script reuses the existing one if present.
- Never delete or remove worktrees from this skill.

## Editing the script

The script is `scripts/worktree.ps1` in the yi-sdlc plugin repo, `C:\Projects\Pet\yi-sdlc` (the running copy is
`${CLAUDE_PLUGIN_ROOT}/scripts/worktree.ps1`). Edit it in that repo, not in the current project.

Parameters and defaults (keep these unless the user asks to change them):
- `-Branch` (position 0): optional; empty means the main clone's current branch.
- `-RepoPath` `C:\Work\Repo\EvenFlow-Backend`, `-WorktreeRoot` = sibling `<repo>-WT`, `-BaseBranch` `master`,
  `-SolutionName` `EvenFlow.sln`, `-RiderPath` auto-detected, `-SkipMemory`.
- `-ReplaceWindow` `[bool]` default `$false`: keep the current Rider window, open the worktree in a new one.
- `-WithChanges` `[bool]` default `$false`: stash the main clone's uncommitted changes (incl. untracked) and pop them
  into the worktree. Must work whichever branch the main clone is on, not only when it is on the worktree branch.
- `-MaximizeOnly`: internal; the detached helper that maximizes the worktree's Rider window.

Design rules:
- Rider is one process with many windows, so match windows by title. The main clone's window is titled exactly
  `<solution>`; worktree windows get a ` [<path>]` suffix. Use an exact match for "the current window" and never a
  prefix match, which also hits worktree windows.
- The script must return quickly (the Rider maximize runs in a hidden detached process).
- Open the `.sln`, not the folder, so Rider loads it as a solution.
- It never commits and never deletes worktrees. The main clone is switched to master only if it is on the worktree
  branch.

Checklist after every edit (scenario-trace each one, run it where it is safe, and say which were only traced):
1. Parse check: `[System.Management.Automation.Language.Parser]::ParseFile(...)` reports no errors.
2. New branch from master, no `-WithChanges`: worktree created, main clone untouched.
3. Main clone on master with uncommitted and untracked changes + `-WithChanges:$true`: changes end up in the
   worktree, the main clone is clean, the stash is empty.
3b. Branch name that does not exist locally but exists on origin (even when the earlier fetch missed it): the
   worktree is created tracking `origin/<branch>`, not a new branch from master.
4. Reusing an existing worktree: no duplicate created; `-WithChanges` with conflicting local edits warns and leaves the
   changes in the stash instead of losing them.
5. Stale worktree entry (folder deleted by hand): `git worktree prune` runs and the branch can be re-added.
6. `-ReplaceWindow:$true` closes only the main clone's own window (exactly one exact-title match), never a worktree
   window; with zero or several matches it closes nothing.
7. Rider opens the worktree's `.sln` and the window is maximized; gitignored files and Claude memory are copied only
   when missing at the destination.
8. The script returns without waiting for Rider.

Do not report an edit as fixed until it was run or its scenario was traced against the checklist; if Rider behaviour
(window refresh, maximize, replace) could not be observed, say so.
