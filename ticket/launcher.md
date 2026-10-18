# Launcher: where a ticket's session runs

Each ticket can run in a Claude session of its own, started inside its worktree in a Rider terminal tab
named after it, so the operator can start several tickets one after another and watch them side by side.
When that isn't possible, or isn't wanted, the work simply runs **here**, in the session the operator
invoked. A failed launch is never a reason to stop: it falls back to here.

The session the operator invoked is the **launcher**. With a tab, it reads the ticket, checks it is the
right skill, brings up the environment, opens the tab and ends; the **tab session** runs the same command
and does the actual work, from the `in-progress` move onwards. Without a tab, the launcher does the work
itself.

## Choose

Profile § Launcher `launcher` says what to try: `rider` (the default when the section is missing) or
`here`. Run here, without trying a tab, when any of these holds, and say which in one line:

- you are the tab session (`$env:YI_SDLC_TAB` equals `<id>`: § In the tab session);
- profile § Launcher says `here`, or the operator said to stay here ("here", "no tab", `--here` in the
  arguments);
- your skill follows `sdlc-mode` and it is `developer` (also the default for an unmarked ticket): it is a
  conversation with the operator, which is already happening here;
- no `mcp__rider__*` tools are available in this session (the `rider` MCP server isn't installed or
  connected).

Otherwise try the tab (§ Rider tab). Every step there names its fallback.

## Rider tab

Needs the `rider` MCP server, the main clone open in Rider, and PowerShell as Rider's terminal shell
(Settings → Tools → Terminal → Shell path).

1. Decide `<branch>` now, from profile § Branches (for `/yi-sdlc:impl-feature`, after its name step). On a
   re-run the ticket already has one (`git branch --list` with the kind's pattern, `{slug}` as `*`): reuse
   it. The tab title is the feature's `<slug>` for `/yi-sdlc:impl-feature`, and `<branch>` for the other
   two.
2. `ticket-env.ps1 up -Issue <id> -Branch <branch>`: the tab starts in the worktree, so it must exist
   first. Keep the printed `worktree`. If `up` fails, that is the environment failing, not the launch:
   handle it as the skill's environment step would (it is not a reason to fall back).
3. Run `${CLAUDE_PLUGIN_ROOT}/ticket/scripts/rider-tab.ps1 -Main <main> -Id <id> -Worktree <worktree>
   -EnvScript <ticket-env.ps1> -Title <title> -Branch <branch> -Prompt "<the command you are running, with
   its arguments>"`, adding `-Setup` and `-ClaudeArgs` when profile § Launcher gives them. It copies the
   main clone's git-ignored Claude files into the worktree, writes a Rider run configuration to
   `<main>\.run\` (git ignores it), and prints its `name` and `file`. **Fails →** fall back.
4. `mcp__rider__read_file` on that file (`rootFolder` = `<main>`): Rider only loads a new run configuration
   once it reads the file. Then `mcp__rider__get_run_configurations` must list `name`; read the file once
   more if it doesn't. **An error saying `<main>` isn't an open project, or `name` still missing →** fall
   back.
5. `mcp__rider__execute_run_configuration` with `configurationName` = `name` and `waitForExit: false`. It
   answers **"The process has failed to start" even when the tab opened**, because a run in the terminal
   has no process for it to track. That answer is success. **Any other error, or a timeout →** fall back.
6. End with one message: the ticket is running in the Rider tab `<title>`, in `<worktree>`, where its
   questions and stops will come up. Claude may first ask there whether to trust the new folder. Don't
   move the ticket or comment on it: the tab session does that, and doing it twice would collide.

### Fall back to here

1. If step 3 wrote a configuration, remove it: `rider-tab.ps1 -Main <main> -Id <id> -Remove`.
2. Say in one line why the tab didn't open (the step and its error) and that the ticket runs here instead.
3. Carry on with the skill in this session, as if it had chosen here in § Choose. The environment is
   already up, and the skill's own `up` reuses it; keep `<branch>`.

The operator may have meant to run several tickets in parallel. Running here still finishes this one; the
message in sub-step 2 lets them fix Rider before starting the next.

## In the tab session

You are the tab session when `$env:YI_SDLC_TAB` equals `<id>`. Then skip the launch, and:

- `<main>` is `$env:YI_SDLC_MAIN` (`git rev-parse --show-toplevel` would give the worktree), and the profile
  is `<main>\.claude\yi-sdlc\project.md`. `<branch>` is `$env:YI_SDLC_BRANCH`: the launcher chose it and
  named the tab after it.
- First, remove the launch configuration: `${CLAUDE_PLUGIN_ROOT}/ticket/scripts/rider-tab.ps1 -Main <main>
  -Id <id> -Remove`. The tab stays open without it.
- You already work in the worktree. `ticket-env.ps1 up` answers at once with the running environment's
  JSON. Skip `EnterWorktree` and `ExitWorktree`.
- You can't remove your own worktree: Windows keeps the folder of a running process in use. Wherever a step
  says `ticket-env.ps1 down -Issue <id>` without `-KeepWorktree` (after the merge, or a Blocked exit with
  nothing worth keeping), run it **with** `-KeepWorktree`. Then `git switch --detach` in the worktree, so
  `git -C <main> branch -D <branch>` can delete the branch. The detached HEAD also tells the tab the ticket
  is finished: when Claude exits, it removes the worktree. Your final message ends with **"Exit Claude
  (`/exit`) to remove the worktree."**
