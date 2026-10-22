---
name: process-tickets
description: >-
  Check a yi-sdlc repo's YouTrack board for what to work on next, rank the ready tickets (features first,
  then tasks of features already running in a Pane), ask the operator which of the top 5 to start, and
  start each pick in Pane: a feature in a new Pane running /yi-sdlc:implement-feature, a task as a tab in
  its feature's Pane. Use it whenever the operator asks what's next, what to pick up, what's ready or
  unblocked on the board or backlog, or wants to kick off the next feature or ticket, even without naming
  the skill. Needs the repo's .claude/yi-sdlc/project.md (YouTrack adapter) and the Pane app.
  Arguments: optional depth (easy|medium|hard, default medium, passed to implement-feature), ticket IDs to
  propose (still confirmed by the operator before anything starts), --dry-run to stop before anything is
  created. By default every start needs the operator's approval; only an explicit --auto [N] lets it pick
  and start the top N (N defaults to 1) without asking.
argument-hint: '[easy|medium|hard] [<key>-N ...] [--auto [N]] [--dry-run]'
---

# Check the board and start the next tickets

The operator runs the repo's work as one Pane per feature (worktree + branch), with the yi-sdlc pipeline
inside it. This skill is the front door: it reads the board, says what is ready and why, lets the operator
choose, and launches the choices, so that several features can run side by side without the operator
working out the blocker graph by hand.

Read `.claude/yi-sdlc/project.md` (the profile) when you need a detail it owns: the project key and ID
normalization, the board columns (§ Tracker), the branch patterns (§ Branches). Examples below use the
key `<key>` (`yv`, `ts`, …). Don't restate them here; naming rules live only in the
`yi-sdlc:git-commit` skill and that profile.

## 0. Arguments

`$ARGUMENTS` may hold, in any order:

- a depth, `easy`, `medium` or `hard` (default `medium`, though implement-feature's own default is
  `easy`), always passed on to `/yi-sdlc:implement-feature` explicitly;
- ticket IDs (`<key>-10`, `<KEY>-10`, `10`, normalized as the profile says): the tickets to propose, once step 2
  confirms they are ready (say so and skip any that aren't). They replace the pick question, not the
  confirmation: step 3 still asks the operator to confirm them before anything starts;
- `--auto [N]` (or "auto"): off by default, so every start needs the operator's approval (step 3). Only
  when the operator passes it do they hand the choice to you. Step 3 asks nothing: you pick and start
  without approval (see step 3 § Auto). `N` is how many to start at most (default `1`). With ticket IDs,
  `--auto` starts those that are ready without the confirmation, and `N` is ignored. It covers the pick
  only: a board move (step 2's "looks done but open") still needs the operator's yes, and so does any
  trust or approval prompt in a new Pane;
- `--dry-run` (or "dry run"): do everything up to step 4 with reads only (no `git fetch` or merge: compare
  against `origin/main` as last fetched and say so), then print the exact commands and prompts instead of
  running them. Nothing is created, copied, fetched or moved.

## 1. Read the board

`<skill dir>` below is `${CLAUDE_PLUGIN_ROOT}/skills/process-tickets`.

Run from the **main clone** (if you are in a worktree, the main clone is the parent of
`git rev-parse --git-common-dir`):

```
python <skill dir>\scripts\board.py --repo-root <main clone>
```

It reads the profile's § Tracker (the project key from `id_pattern`, `column_field`, the `columns` and
their roles: columns before the `in-progress` one are startable, the `in-progress`, `blocked`,
`in-review` and `test` ones are in flight), makes one compact YouTrack REST call (the MCP search returns
~75 KB for 50 issues, which is why it exists), lists the repo's Panes and branches, and prints JSON. When
the repo has no profile, its adapter isn't `youtrack`, or no column has the `in-progress` role, the script
exits with the reason: say it and stop.

Pane has to be running for both halves of this skill: the ranking needs it to know which features already
have a Pane (without it a started feature looks fresh and could get a second Pane), and step 5 creates Panes
through it. So when the app isn't running the script launches it (the installed app `runpane doctor` finds)
and waits up to 90 s for it to answer. Launching the app creates nothing, so `--dry-run` does it too;
pass `--no-start-pane` only if the operator asked you not to start Pane.

The JSON:

- `top`: the ranked candidates, at most 5. Each has `kind` (`feature` or `task`), `action` (`new-pane` or
  `tab`), `priority`, `stage`; a feature has `slug`, `tasks_open`, `tasks` (its open subtask IDs),
  `first_task`; a task has `feature`,
  `feature_slug`, `task_id` (its `T<n>` in the feature's `tasks.json`) and the feature's `pane`.
- `in_flight`: features already started (a Pane, a branch, or an in-progress column).
- `blocked`: features waiting on open blockers; `looks_done: true` marks a blocker that is really finished.
- `stale`: open features whose subtasks are all resolved, i.e. done work the board never closed.
- `pane_app`: `state` is `running`, `started` (this run launched it) or `down` (with a `reason`).
- `warnings`: e.g. Pane wasn't reachable, so Pane state is missing from the ranking.

If `pane_app.state` is `down`, say why and stop before step 3: the ranking can't see which features are
already in flight, and nothing can be started. Ask the operator to open Pane and run the skill again.

If it is `started`, say so in one line. A Pane restart leaves every agent tab in the existing Panes stopped
(`running: false`), so list those Panes under **In flight** as stopped. Resuming a tab relaunches its agent,
so it's the operator's call: offer `runpane panels resume --panel <panel-id> --yes`, but don't run it
unasked. A task tab can
still be added to a Pane whose own agent is stopped.

The ranking: unblocked features first, because a feature is what gets a new Pane and runs the whole
pipeline. Then tasks of features already running in a Pane whose own blockers are done and which are in that
feature's `tasks.json` (a task of a feature that isn't started yet is not its own row: starting the feature
starts it). Within each group: Priority (Major before Normal before Minor), then the order of
`docs/roadmap.md` (the owner's blocker-graph order), then issue number.

If the script fails (no token, network), say what failed. Don't fall back to guessing from the roadmap: a
stale ranking is worse than none. The MCP tools (`mcp__youtrack__search_issues`, `get_issue_links`) can
stand in, at a much higher token cost, if the operator wants to go on.

## 2. Show the picture

One compact message. Start with the table of `top`:

| # | Ticket | Kind | What | Priority | Why it's ready | Starts as |
|---|---|---|---|---|---|---|

"Why it's ready" is one short clause: "blocker <key>-9 shipped", "no blockers", "T2 done, its feature runs
in Pane `agent-sessions`". "Starts as": "new Pane `<slug>`, implement-feature" or "tab in Pane `<pane name>`".

Under it, only the lines that have content:

- **In flight:** each feature with its Pane name and agent state (`blocked` means it waits on the
  operator; worth saying first).
- **Looks done but open:** each `stale` item with its reason, and what it holds up (the `blocked` entries
  whose blocker has `looks_done`). Offer to move them to Done, but only do it if the operator says so. A
  merged PR is the proof to check (`gh pr list --state merged --search <slug>`); the board move is
  outward-facing and theirs to approve. Ask about the move on its own: never put "and start <key>-N" in
  the same question or option. After a move, run step 1 again and show the new picture; whatever the move
  unblocked goes through step 3 like any other candidate.
- **Blocked:** the top 2–3 by priority with their open blockers, so the operator sees what unblocks next.

If `top` is empty, say what would unblock the next item and stop.

## 3. Ask which to start, then confirm

Nothing starts until the operator has confirmed the exact set: which tickets and how many. This holds
when the arguments named tickets, when there is a single candidate, and when the candidate only became
ready because the operator approved a board move a moment ago. The exceptions are `--dry-run`, which
starts nothing, and `--auto`, where the operator has approved in advance.

**Pick.** Skip this question when the arguments named tickets (they are the picks). `AskUserQuestion`
allows at most 4 options per question, so:

- 1 candidate: ask "Start <key>-N (<summary>)?" with Start / Not now.
- 2–4 candidates: one `multiSelect` question listing them all.
- 5 candidates: two `multiSelect` questions, "Ranks 1–3" (three options + "None of these") and
  "Ranks 4–5" (two options + "None of these"), so every candidate stays visible.

Each option label is `<key>-N <slug or short title>`; its description gives the kind, priority and how it
starts. No pick means stop with nothing started.

**Confirm.** Then ask one more question, on its own, that states the count and lists every pick with how
it starts: "Start 2 tickets: <key>-15 chart-alerts (new Pane `chart-alerts`, implement-feature medium),
<key>-21 (tab in Pane `backtesting`)?" with Start these / Change the picks / Cancel. "Change the picks"
goes back to the pick question; "Cancel" stops with nothing started. The single-candidate question above
already names one ticket, so when it gave Start and its description said how the ticket starts and at
what depth, it counts as the confirmation.

Starting more than one is fine; that is the point of a Pane per feature. If two picks would collide (a
feature and a task of the same feature, or two tasks of one feature whose `files_hint` overlap in
`tasks.json`), say so in the confirmation question.

**Auto.** With `--auto`, skip both questions and pick yourself: walk `top` in rank order and take each
candidate until you have `N`, skipping one that would collide with a pick you already took (say which and
why). A task whose feature's session is implementing right now (step 5's check) counts as a collision
too. Before step 4, print one line with the count and the picks, in the confirmation question's words
("Starting 1 ticket: <key>-15 chart-alerts (new Pane `chart-alerts`, implement-feature medium)"), then go
on without waiting.

## 4. Get ready to start

For every pick, before anything is created:

1. **Base branch is current.** `git -C <main> fetch origin`. If `main` is behind `origin/main` and the
   main clone is on `main` with no tracked changes, `git -C <main> merge --ff-only origin/main`; otherwise
   say it's behind and go on from local `main`. A feature started from an old main redoes merged work.
2. **Feature pick:** its branch is the profile's § Branches `feature` pattern with `{id}` and `{slug}`
   (e.g. `feature/<key>-10-agent-sessions`). The Pane name is `<slug>`. Check that neither a Pane of that name
   nor that branch exists (`git branch -a --list "*<id>*"`); the script already treats either as "in flight",
   so a clash here means something changed: stop on that pick and report it.
3. **Task pick:** its feature's Pane must still exist (`mcp__pane__panes_list`), and the feature's
   `tasks.json` entry for the task (`task_id`) must exist in that Pane's worktree.

## 5. Start them

In `--dry-run`, print for each pick the command (or MCP call with its arguments) and the full prompt
text, then stop. Otherwise:

### A feature: a new Pane running implement-feature

`/yi-sdlc:implement-feature` can't be invoked by you (it has `disable-model-invocation`), so the Pane agent
gets it as its first typed command. It recognises the Pane it runs in as the ticket's (by the branch) and
brings up `ticket-env.ps1` around that worktree; the note only passes on what this skill already settled.

1. Write the prompt to `$env:TEMP\process-tickets\<id>.md`:

   ```
   /yi-sdlc:implement-feature <id> <depth> --stop-at-gates

   Started by /yi-sdlc:process-tickets in this ticket's own Pane: you already run in its worktree <worktree>
   on branch <branch>, made from main. The main clone is <main>.
   - The feature name is chosen: <slug>. Don't ask for it in step 2; your slug, commit prefix and branch
     follow from it.
   - The board already has this feature's tasks: <open subtask IDs>. At break-tasks, map tasks.json
     entries onto them (its `ticket` field) and create tickets only for tasks they don't cover.
   ```

   Fill the angle-bracket values; `<open subtask IDs>` is the candidate's `tasks` (drop that line when
   it is empty). `<worktree>` is the path Pane will create: the repo's worktrees folder (the `worktreePath` of an
   existing Pane of this repo shows it, e.g. `<main>\worktrees\<slug>`). Check it against the create command's
   JSON afterwards, and send a correction with `mcp__pane__agents_send` if it differs; fix the prompt
   file too. Keep the file: the gate driver (sub-step 5) sends it again after every gate, and
   `--stop-at-gates` is what makes the session stop there for it.

2. Create the Pane (`runpane` is `%USERPROFILE%\.pane\bin\runpane.cmd` when it isn't on PATH):

   ```
   runpane panes create --repo <main> --name <slug> --branch <branch> --base-branch main
     --agent claude --prompt-file <prompt file> --wait-ready --no-focus --yes --json
   ```

   `--yes` is right here: the operator confirmed this ticket in step 3 (or handed you the choice with
   `--auto`), and that is the confirmation Pane asks for.

3. Copy the git-ignored Claude files the worktree lacks: `<main>\.claude\sdlc.local.md` (the operator's
   yi-sdlc settings; without it the stages fall back to plugin defaults) and
   `<main>\.claude\settings.local.json` (the YouTrack MCP approval and permissions). Don't overwrite
   ones that exist.

4. `mcp__pane__agents_status` on the new panel. If Claude is sitting on a trust-folder or MCP-approval
   prompt instead of working, don't answer it: tell the operator it is waiting for them in that Pane.

5. Start the gate driver as a `gates` tab in the same Pane, with the Pane id and the agent's panel id from
   step 2:

   ```
   runpane panels create --pane <pane id> --title gates --source agent --no-focus --yes --json
     --tool-command "powershell -NoProfile -ExecutionPolicy Bypass -File <skill dir>/scripts/gate-driver.ps1 -Pane <pane id> -Panel <panel id> -Prompt <prompt file>"
   ```

   `<skill dir>` here is the absolute path, with `${CLAUDE_PLUGIN_ROOT}` already expanded (e.g.
   `C:/Projects/Pet/yi-sdlc/skills/process-tickets`): the tab's shell doesn't know the variable. **Write both
   paths with forward slashes.** Pane types the command into the Pane's own shell, which can be Git Bash,
   and bash eats backslashes: `C:\Projects\Pet\…` arrives as `C:ProjectsPet…` and the driver never
   starts. Then check the tab once with `mcp__pane__agents_status` on its panel: its screen should say
   `Watching panel <panel id> for approved gates`. Anything else (a "does not exist" error, a bare
   prompt) means no driver is running: the session then finds no driver's marker at gate 1 and goes on
   without clearing, so fix the tab and start the driver again.

   After each gate the operator approves, the session reports it and ends its turn; the driver then sends
   it `/clear` and the prompt file again, so every stretch between gates starts with a fresh context and
   implement-feature resumes from its **Feature pipeline** comment. The driver never answers a gate, and
   it closes itself after gate 3 or when the session exits. When the operator ticks Keep Recommended in
   the question window, the session approves the gates itself (implement-feature § Auto mode) and the
   driver still clears it after each one, so the run goes from gate to gate without anyone at the Pane.

### A task: a tab in its feature's Pane

`mcp__pane__agents_start` with `pane: <the feature's pane id>`, `agent: claude`, `yes: true`, and this
prompt:

```
Started by /yi-sdlc:process-tickets as a task tab in the <feature_slug> Pane. Implement only YouTrack task <id>:
docs/features/<feature_slug>/tasks/tasks.json entry <task_id>. Do it the way /yi-sdlc:implement-tasks
does one task: failing test first, the minimal code to pass, refactor, the gates in AGENTS.md, one
commit with the feature's prefix. Move <id> to In Progress when you start and to Done after the commit,
and mark <task_id> done in tasks/tracker.md. Leave everything else to the feature's own session in
this Pane: no other tasks, no push, no PR, no comments or moves on the feature ticket <feature>.
```

A task tab shares the worktree with the feature's own session. If that session is implementing right now
(`agentState: working` and its `tracker.md` shows tasks in progress), say that the two may edit the same
files and let the operator decide whether to go ahead. Under `--auto`, don't start it: skip it and say
why.

## 6. Report

One message: per started ticket, its Pane and panel and a clickable link (`mcp__pane__links_create`),
and where its questions will come up: implement-feature's interview questions, its three gates (PRD,
architecture, plan) and the merge approval all appear in that Pane, and its `gates` tab clears the session
after each approved gate. Ticking Keep Recommended on one of its questions puts that run in auto mode: it
stops only for questions headed Critical. Under `--auto`, say that you chose the picks and which ranked
candidates you passed over. Mention anything skipped and why, and
repeat the "looks done but open" items if the operator didn't act on them.

## Notes

- Epics are never candidates: they are containers, and their features are what gets built.
- A Pane is costly to create (a worktree, then install and build), so never create a second one for a
  feature that has one. Later agents for it (review, fix, QA) are tabs in it.
- The board drifts: tickets stay in Backlog after their PR merged. Trust merged PRs and resolved subtasks
  over the column, but report the drift rather than fixing it silently.
