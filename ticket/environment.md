# Isolated environment contract

Every ticket runs in an environment of its own, so the operator's checkout and dev stack stay untouched:
they may be using them while the agent works. What that environment *is* (a worktree only, or a worktree
plus its own database, services and ports) is entirely the repo's business. The repo ships a script that
builds and removes it, and profile § Environment names the script and describes it. This file is the
interface the plugin relies on, and nothing more. The plugin has no environment code of its own.

## The script

A PowerShell script in the repo (by convention `.claude/yi-sdlc/ticket-env.ps1`), run from the main clone
with the PowerShell tool, **always by its absolute path in the main clone**: `<main>` below is
`git rev-parse --show-toplevel` there. The worktree
has its own copy of the script, which would resolve its paths from the worktree and build the wrong
environment. The workflow and skills write it as `ticket-env.ps1`, meaning that absolute path.

It must accept these commands, take the ticket ID as `-Issue <id>`, and print JSON on success:

| Command | Must |
|---|---|
| `up -Issue <id> -Branch <branch>` | Create a git worktree on `<branch>`, new from the base branch (profile § Branches `base`), or reuse the branch and the worktree when they exist; give it what it needs to run on its own; start what the live check needs. Idempotent: on a running environment, answer at once. Print at least `worktree` (absolute path), plus whatever profile § Environment lists (URLs, log paths) |
| `status -Issue <id>` | Print the same JSON, plus whether each process is alive |
| `restart -Issue <id>` | Make the running environment reflect the worktree's current code: rebuild and restart what doesn't hot-reload, apply new migrations. A repo with nothing to restart makes it a no-op that prints the JSON |
| `down -Issue <id> [-KeepWorktree]` | Stop everything `up` started and remove what it created, then the worktree, unless `-KeepWorktree`. Refuse to remove a worktree with real uncommitted work, and say so |

Profile § Environment may list **more commands** (an end-to-end run, a data reset), with what each does.
The workflow and skills call those only where the profile refers to them, typically from profile § Gates.

## Rules for the agent

- **Edit only inside the worktree** (absolute paths under the printed `worktree`), and run git and the
  build tools there. Never change files in the main clone, docs included.
- Data the environment copies is a snapshot from `up`. Migrations, loads and deletes land in the copy only.
- Profile § Environment lists what the isolated app still reaches outside itself (live services, paid
  APIs) and what must never happen there.

## Writing one

Start from the repo's dev setup: what the operator runs locally, which ports and data it uses. The script
should never reuse any of it. Free ports (ask the OS for them), a copy of the data rather than the data, a
worktree next to the main clone rather than inside it, and the state (ports, PIDs) in a file outside the
worktree so `status` and `down` find it. Windows PowerShell 5.1 compatible, so it runs from any
terminal and Claude's PowerShell tool alike.
