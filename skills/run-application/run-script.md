# Run script contract

The interface `/yi-sdlc:run-application` relies on to start a repo's application from any of its checkouts.
The point is parallel work: two Claude sessions in two worktrees each change the app, and the operator wants
to try either result, or both side by side, without stopping the other or their own dev run. So every
checkout runs on ports of its own, and the script says where.

What starts (a backend, a frontend, a worker, a database container) is the repo's business. The repo ships
the script; this file is all the plugin assumes about it. `templates/run-app.ps1` implements it, so a repo
normally only fills in that template's `$Parts`.

## The script

A PowerShell script, by convention `.claude/yi-sdlc/run-app.ps1`, that runs under Windows PowerShell 5.1 and
pwsh 7 alike, so it works from Claude's PowerShell tool and a Rider terminal. Profile § Run, when the repo has
`.claude/yi-sdlc/project.md`, names it if it lives elsewhere.

`-Path <dir>` picks the checkout (any folder inside it); without it, the checkout the script itself is in. A
checkout whose branch predates the script is run by the main clone's copy with `-Path`.

| Command | Must |
|---|---|
| `up [-Path]` | Start every part that isn't running, wait until each answers, print the report. Idempotent: on a running checkout, answer at once with the same PIDs |
| `status [-Path]` | Print the report; start nothing |
| `restart [-Path]` | Stop what `up` started and start it again on the same ports, so open browser tabs keep working (for changes that don't hot-reload) |
| `down [-Path]` | Stop everything `up` started for that checkout, nothing else |
| `list` | Print a report for every checkout in `git worktree list` |

On failure: exit 1, and print to stderr which part failed and the tail of its log.

## The report

```json
{
  "checkout": "C:\\Projects\\shop-WT\\feat",
  "branch": "feat",
  "head": "a599d85",
  "main": false,
  "running": true,
  "links": [ { "name": "Shop", "url": "http://localhost:53405/", "status": 200, "ok": true } ],
  "parts": [ { "name": "web", "port": 53405, "running": true, "by": "run-app", "pid": 6796, "commit": "a599d85", "stale": false, "log": "…\\web.out.log" } ],
  "state": "C:\\Users\\…\\AppData\\Local\\yi-sdlc\\run\\shop-1a2b3c4d\\feat-2c57c9e2"
}
```

- `links`: what the operator clicks, only for parts that are up. `ok` means the link answered 2xx/3xx when
  the report was made.
- `parts[].by`: `run-app` (this script started it), `external` (something else already serves the main
  clone's usual port, typically the operator's own dev run, which the script leaves alone), `shared` (one
  instance for all checkouts, never stopped by `down`), or null (not running).
- `parts[].stale`: the part answers, but with older code than the checkout has. HEAD changed what it
  watches, or a watched file was written after it started. Never true for a part that hot-reloads.
  `commit` is the HEAD it started from.
- `list` prints an array of these.

## Rules

- **Ports.** The main clone uses each part's usual port, so the operator's bookmarks keep working. A
  worktree gets free ports from the OS, kept in its state file and reused while they stay free, so its links
  survive a restart.
- **Wiring.** Each part reaches the other parts of *its own* checkout: the frontend's API proxy target, the
  backend's CORS origin and callback URLs all come from `{port:<part>}`, never a hard-coded port. A config
  that hard-codes one needs a small repo change (read an environment variable, with the old value as the
  default); propose it rather than slipping it in.
- **Shared parts.** Something every checkout can safely use (a dev database container) is one shared
  instance. Anything a worktree would change in a way that hurts the others (migrations at startup against a
  shared database, a shared cache with incompatible schemas) is the repo's call to make, written down in
  the script's header and profile § Run.
- **State outside the checkouts.** Ports, PIDs, start times and logs live in
  `%LOCALAPPDATA%\yi-sdlc\run\<repo>-<hash>\…`, so no
  checkout gets untracked files and `list` can find every instance.
- **Detached.** The started processes outlive the call, and none inherits the script's output handles; a
  caller reading the JSON through a pipe would otherwise wait for the servers to exit.
- **Ticket worktrees** made by `ticket-env.ps1` (the ticket kit's `environment.md`) already run in their own
  isolated environment. `/yi-sdlc:run-application` asks `ticket-env.ps1` for those; this script doesn't
  need to handle them.
