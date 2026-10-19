---
name: run-application
description: >-
  Start the repo's application (backend, frontend, workers, database) from any checkout, the main clone or
  any git worktree, each on its own ports so several run side by side, and answer with the links to try
  it, each checked live. Built for parallel Claude sessions in different worktrees: "run the app for yv-5",
  "show me what the other session built", "links for all worktrees", "stop the feat app", "restart it".
  Drives the repo's .claude/yi-sdlc/run-app.ps1 (up | status | restart | down | list); when the repo has
  none yet, writes it from the bundled template after reading the repo's dev setup. Use it whenever the
  user wants to run, start, open, try, click through or see the app or a branch's result, asks which
  instances are running or where to find them, or wants one stopped or restarted, even if they never say
  "worktree". Also: "запусти застосунок", "підніми додаток", "дай посилання", "покажи результат".
argument-hint: "[checkout | branch | ticket-id | all] [up | status | restart | stop]"
---

# Run the application

The operator works with several Claude sessions at once, each in its own worktree, and wants to try any
session's result without stopping the others or their own dev run. This skill starts the app for the
checkout they mean and hands back links that work. **A link the operator clicks and finds dead costs more
than no link**, so only call a link working when the script checked it just now.

The repo owns what starts; the plugin owns the interface. Read `run-script.md` (next to this file) before
writing or fixing a script. Running an existing one needs only the steps below.

## 1. Which checkout, which action

Arguments: `$ARGUMENTS`.

- **Checkout.** List them with `git worktree list --porcelain` (run in any checkout). Match the argument
  against the worktree folder name, the branch, a ticket ID, or a path. Nothing given: the checkout this
  session is in (`git rev-parse --show-toplevel`). `all` (or "every session", "what's running"): `list`.
  Two candidates match: ask which one, listing both with their branch.
- **Action.** Default `up`. "status", "is it running", "links" → `status`. "restart", "reload the backend",
  after code changes that don't hot-reload → `restart`. "stop", "kill", "shut down" → `down`.

## 2. The repo's notes

If `.claude/yi-sdlc/project.md` exists in the main clone, read its § Run (where the script lives, what
the checkouts share, what must never happen in a worktree) and § Environment (ticket worktrees).

**A ticket worktree** (profile § Environment names the folder the ticket worktrees go to; the worktree's
folder name is the ticket ID) already has its own isolated environment, with its own database copy. Use it
rather than starting a second copy: `ticket-env.ps1 status -Issue <id>` by its absolute path in the main
clone. When it is down and the action is `up`, run `ticket-env.ps1 up -Issue <id> -Branch <its branch>`
(`restart` and `down` map to the same commands). Its JSON has the URLs (`web`, `api`, …); show those in
step 4 and check each one with a request first, since that JSON has no `ok`.

Its JSON doesn't say whether the backend runs the branch's current code either, and a backend that doesn't
hot-reload often doesn't: the session committed after the environment came up. Compare the start time of
the process listening on the api port (`Get-NetTCPConnection -State Listen -LocalPort <port>` →
`OwningProcess` → `Get-Process` `StartTime`) with the branch's latest commit (`git log -1 --format=%cI`)
and with the write times of its uncommitted changes. If the process is older, report it as stale (step 4)
and offer `ticket-env.ps1 restart -Issue <id>`, but ask first: that environment belongs to the session
working there, and a restart cuts into whatever it is checking.

## 3. Run the script

The script is `<checkout>\.claude\yi-sdlc\run-app.ps1`, or profile § Run's path. If that checkout has no
copy (its branch predates the script), use the main clone's copy with `-Path <checkout>`. Neither exists:
write one first (§ Writing the script).

Run it with the PowerShell tool, by absolute path, with a long timeout (600000 ms: a first `dotnet build`
or `npm install` is slow):

```powershell
& '<script>' up -Path '<checkout>'
```

It prints JSON (`run-script.md` § The report). A part with `stale: true` answers, but with older code than
the checkout has (HEAD moved or its files changed since it started, and it doesn't hot-reload). The operator
asked to see the current result, and this instance is the operator's own (`by: run-app`), so run `restart`
right away and report from that.

On exit 1, stderr has the part that failed and its log tail. Read it and say what broke in a sentence or
two, quoting the decisive log line. Fix what is the environment's fault (a missing `npm install`, a port held by a stale process the script itself started)
and retry once. Code that doesn't build or crashes on start is the session's work; report it, don't
"fix" another session's branch.

## 4. Answer with the links

Lead with the links. Per checkout:

```
**shop** · `feat` · worktree `C:\Projects\shop-WT\feat`
Latest: `a599d85` Add the basket badge (12 min ago) · 7 commits ahead of `main` · no uncommitted changes

| | Link |
|---|---|
| ✅ Basket (this branch's work) | http://localhost:53405/basket |
| ✅ Shop | http://localhost:53405/ |
| ✅ API docs | http://localhost:53378/swagger |

Logs: `C:\Users\…\yi-sdlc\run\shop-1a2b3c4d\feat-2c57c9e2`
```

- The "Latest" line tells the operator which state of the session's work they are looking at:
  `git log -1 --format='%h %s (%cr)'`, `git rev-list --count <base>..HEAD`, `git status --porcelain`.
- When the branch's work clearly lives on one page (a route the diff adds or changes), put that link first.
  When the branch changes nothing the app runs (docs, rules, tests only), say so: the app is the base
  branch's, and the work is in the diff.
- ✅ only for `ok: true`. A link that isn't ok gets ❌ and its status (`404`, `no answer`), and stays in the
  table, because the operator should see what's missing.
- A part still stale after all (a ticket environment you didn't restart): a ⚠️ line under the table naming
  the part, the commit it runs and the branch's HEAD, and the command that refreshes it.
- No API docs page (`/swagger`, `/scalar`, `/docs` all 404)? Show the health URL or the OpenAPI JSON
  instead, not a dead link.
- `by: external` means the operator's own run serves that part (main clone only): say "already running
  (yours), left alone".
- For `all`: one block per checkout that runs something, then one line naming the ones that don't, with
  their branch, so the operator can ask for them.
- After `down`: one line saying what stopped. Shared parts (a database container) stay up: say so.
- End with the next useful command, e.g. `/yi-sdlc:run-application feat restart` after backend changes.

Don't open a browser unless asked. The operator decides which tab they want.

## Writing the script

The repo has no run script. Build it from the template, wired to this repo's real dev setup, so that every
later run is one command.

1. **Read the dev setup:** README / AGENTS.md / CLAUDE.md run instructions, `package.json` scripts (root and
   each app folder), `compose.yaml` / `docker-compose*.yml`, `Properties/launchSettings.json` and
   `appsettings*.json` (ASP.NET ports and connection strings), `vite.config.*` / `next.config.*` /
   `angular.json` (dev port, proxy target), existing start scripts (`scripts/`, `Makefile`, `Procfile`,
   `.vscode/launch.json`, Rider run configurations), `.env*` examples.
2. **Decide each part:** what starts it, the main clone's usual port, how a port is handed to it (`--port {port}
   --strictPort` for Vite, `--urls http://localhost:{port}` for ASP.NET, `PORT` for many Node servers), the
   readiness URL (a `/health` endpoint if there is one, else `/`), the links worth showing (the app, API
   docs such as `/swagger` or `/scalar` if they exist, an admin page), whether it hot-reloads (`HotReload`:
   Vite, `dotnet watch`, nodemon), and, when `Dir` is the repo root, the paths whose changes need a restart
   (`Watch`, e.g. `src`), so stale reports stay precise.
3. **Wire each part to its own checkout.** The frontend's proxy or API base URL must point at
   `{port:<backend>}`. Find where the target comes from. If it is hard-coded, propose the smallest change
   that reads an environment variable with the current value as its default, and make it only once the
   operator agrees. Without it, a worktree's frontend silently talks to the main clone's backend and the
   operator ends up testing the wrong code.
4. **Shared or per checkout.** A database server is usually one shared part (`Shared = $true`, `Run =
   'docker compose up -d <service>'`, Ready `tcp://localhost:<port>`). Check whether the backend applies
   migrations or seeds at startup. If it does, a worktree with new migrations would change the shared
   database under every other checkout. Ask the operator; the usual answer is a database per worktree in
   the same server: the backend's `Worktree = @{ Env = @{ <connection string> = '…Database=<app>_wt_{slug}…' } }`
   plus a `Build` that creates it as a copy of the dev database once, and a `Stop` only if they want it
   dropped on `down`. Write the answer into the script's header.
5. **Leave the checkout as it was.** Another session owns that worktree, and anything the run writes there
   shows up in its `git status` or breaks its build. Build into the state folder (`dotnet build -o
   {state}\api`, then run the DLL from there), so the session's own `bin\` isn't locked by a running process.
   Note `git status --porcelain` before the first `up` in a worktree and compare after: generators that run
   on start (OpenAPI documents, route trees, typed clients) rewrite tracked files. Turn that generation off
   for the run (a build property, a plugin option), or point its output at `{state}`.
6. **Write it:** copy `${CLAUDE_PLUGIN_ROOT}/skills/run-application/templates/run-app.ps1` to
   `<checkout>\.claude\yi-sdlc\run-app.ps1` and replace only the `$Parts = @( … )` block (its header comment
   explains every field). Keep the generic code below it as it is: it handles the ports, the state, the
   detaching, readiness, staleness and the reports under both Windows PowerShell 5.1 and pwsh 7, and repos
   that share it stay easy to update. If it has a real bug, fix that in the repo's copy with the smallest
   change and tell the operator, so the template gets the same fix. Add a line to the `.SYNOPSIS` saying
   what this repo's parts are and what they share.
7. **Prove it:** `up` in this checkout, then check every link answers. If another worktree exists, `up`
   there too, and confirm that its frontend reaches its own backend: a request through the frontend's port
   (its proxy) whose answer or backend log shows that worktree, not the main clone. A scripted request is
   proof enough; no browser needed. No other worktree you may start (only ticket worktrees, or ones busy
   sessions own)? A worktree run alone proves it, since its ports aren't the defaults the config falls back
   to. Fix the script until it passes, then show the links as in step 4.
8. **Record it:** if `.claude/yi-sdlc/project.md` exists, add or update its § Run (format in
   `${CLAUDE_PLUGIN_ROOT}/ticket/profile-template.md` § Run). If that file has uncommitted changes, propose
   the text in your answer instead of mixing it into someone else's work. Tell the operator the script is uncommitted on
   `<branch>`, and that it has to reach the base branch for other worktrees to have their own copy. Until
   then, the main clone's copy serves them through `-Path`, so writing it in the main clone covers everyone
   soonest. Offer to commit it (the `yi-sdlc:git-commit` conventions).

## Don'ts

- Don't touch the operator's own dev run. A main-clone part whose port is already served stays as it is
  (`by: external`). Never kill a process the script didn't start.
- Don't start anything in a ticket worktree beside its `ticket-env.ps1` environment (step 2), and don't
  restart or stop that environment without the operator's yes.
- Don't report a link as working from the JSON of an earlier call: run `status` again if time has passed or
  code changed.
- Don't edit another session's worktree to make its app start. Report what fails and where.
