---
name: process-tickets
description: >-
  Check a yi-sdlc repo's YouTrack board for what to work on next, rank the ready tickets (features first,
  then tasks of features already running in a Pane), ask the operator which of the top 5 to start, and
  start each pick: a feature by giving the operator its /yi-sdlc:implement-feature command (which opens the
  feature's own Pane), a task as a tab in its feature's Pane. Use it whenever the operator asks what's next, what to pick up, what's ready or
  unblocked on the board or backlog, or wants to kick off the next feature or ticket, even without naming
  the skill. Needs the repo's .claude/yi-sdlc/project.md (YouTrack adapter) and the Pane app.
  Arguments: optional depth (easy|medium|hard, default medium, put in the implement-feature command),
  ticket IDs to propose (still confirmed by the operator before a task tab starts), --dry-run to stop
  before anything is created. By default the operator picks; only an explicit --auto [N] lets it pick the
  top N (N defaults to 1) itself.
argument-hint: '[easy|medium|hard] [<key>-N ...] [--auto [N]] [--dry-run]'
---

# Check the board and start the next tickets

The operator runs the repo's work as one Pane per feature (worktree + branch), with the yi-sdlc pipeline
inside it. This skill is the front door: it reads the board, says what is ready and why, lets the operator
choose, and starts the choices, so that several features can run side by side without the operator
working out the blocker graph by hand. It doesn't open Panes: a feature's Pane, worktree and branch are
`/yi-sdlc:implement-feature`'s to open (workflow § Hand it off to the Pane), and that command is the
operator's to run, so for a feature this skill hands them the command.

Read `.claude/yi-sdlc/project.md` (the profile) when you need a detail it owns: the project key and ID
normalization, the board columns (§ Tracker), the branch patterns (§ Branches). Examples below use the
key `<key>` (`yv`, `ts`, …). Don't restate them here; naming rules live only in the
`yi-sdlc:git-commit` skill and that profile.

## 0. Arguments

`$ARGUMENTS` may hold, in any order:

- a depth, `easy`, `medium` or `hard` (default `medium`, though implement-feature's own default is
  `easy`), always written into the `/yi-sdlc:implement-feature` command explicitly;
- ticket IDs (`<key>-10`, `<KEY>-10`, `10`, normalized as the profile says): the tickets to propose, once step 2
  confirms they are ready (say so and skip any that aren't). They replace the pick question, not the
  confirmation: step 3 still asks the operator to confirm a task tab before it starts;
- `--auto [N]` (or "auto"): off by default, so the operator picks and every task tab needs their approval
  (step 3). Only when the operator passes it do they hand the choice to you. Step 3 asks nothing: you pick,
  and start the task tabs without approval (see step 3 § Auto). `N` is how many to pick at most (default
  `1`). With ticket IDs, `--auto` takes those that are ready without the confirmation, and `N` is ignored.
  It covers the pick only: a board move (step 2's "looks done but open") still needs the operator's yes;
- `--dry-run` (or "dry run"): do everything up to step 4 with reads only, then print the commands for the
  feature picks and the exact call and prompt for each task tab instead of starting it. Nothing is created
  or moved.

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
have a Pane (without it a started feature looks fresh and could get a second Pane), and step 5 adds task
tabs through it. So when the app isn't running the script launches it (the installed app `runpane doctor` finds)
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
in Pane `agent-sessions`". "Starts as": "`/yi-sdlc:implement-feature <key>-N <depth>` (opens its own Pane)"
or "tab in Pane `<pane name>`".

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

The operator picks; nothing starts until they have. A feature pick starts nothing here: step 5 gives
the operator its command, and running it is their confirmation. A task pick starts a tab, so it needs
the confirmation below: which tickets and how many. This holds when the arguments named tickets, when
there is a single candidate, and when the candidate only became ready because the operator approved a
board move a moment ago. The exceptions are `--dry-run`, which starts nothing, and `--auto`, where the
operator has approved in advance.

**Pick.** Skip this question when the arguments named tickets (they are the picks). `AskUserQuestion`
allows at most 4 options per question, so:

- 1 candidate: ask "Start <key>-N (<summary>)?" with Start / Not now.
- 2–4 candidates: one `multiSelect` question listing them all.
- 5 candidates: two `multiSelect` questions, "Ranks 1–3" (three options + "None of these") and
  "Ranks 4–5" (two options + "None of these"), so every candidate stays visible.

Each option label is `<key>-N <slug or short title>`; its description gives the kind, priority and how it
starts. No pick means stop with nothing started.

**Confirm** when the picks include a task. Ask one more question, on its own, that states the count and
lists every pick with how it starts: "Start 2 tickets: <key>-21 (tab in Pane `backtesting`), <key>-15
chart-alerts (command `/yi-sdlc:implement-feature <key>-15 medium` for you to run)?" with Start these /
Change the picks / Cancel. "Change the picks" goes back to the pick question; "Cancel" stops with nothing
started. The single-candidate question above already names one ticket, so when it gave Start and its
description said how the ticket starts, it counts as the confirmation. When every pick is a feature,
don't ask it: go on to step 5.

Starting more than one is fine; that is the point of a Pane per feature. If two picks would collide (a
feature and a task of the same feature, or two tasks of one feature whose `files_hint` overlap in
`tasks.json`), say so in the confirmation question, or next to the commands when there is none.

**Auto.** With `--auto`, skip both questions and pick yourself: walk `top` in rank order and take each
candidate until you have `N`, skipping one that would collide with a pick you already took (say which and
why). A task whose feature's session is implementing right now (step 5's check) counts as a collision
too. Before step 4, print one line with the count and the picks, in the confirmation question's words
("Picked 1 ticket: <key>-15 chart-alerts (command `/yi-sdlc:implement-feature <key>-15 medium` for you to
run)"), then go on without waiting.

## 4. Get ready to start

For every task pick, before anything is created: its feature's Pane must still exist
(`mcp__pane__panes_list`), and the feature's `tasks.json` entry for the task (`task_id`) must exist in that
Pane's worktree. Otherwise skip it and say why.

A feature pick needs nothing here: `/yi-sdlc:implement-feature` fetches the base branch, checks the
branch and the Pane, and opens them itself when the operator runs it.

## 5. Start them

In `--dry-run`, print the feature commands as below, and for each task pick the MCP call with its arguments
and the full prompt text, then stop. Otherwise:

### A feature: the command for the operator

`/yi-sdlc:implement-feature` can't be invoked by you (it has `disable-model-invocation`), and it opens the
feature's Pane, worktree and branch itself: run from the main clone, it asks for the feature name, opens
the Pane with its own Claude agent and the `gates` tab, and hands the run to it. So give the operator one
command per feature pick, to run in a Claude session in the main clone (one session per command; each
ends once its Pane is up):

```
/yi-sdlc:implement-feature <id> <depth>
```

Next to each command, say what to answer when it asks for the feature name: the candidate's `slug` (the
name the board ranking used, e.g. `agent-sessions`), unless the operator wants another. When the candidate
has open subtasks (`tasks`), say they are the feature's tasks on the board; implement-feature maps them at
break-tasks itself.

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

One message:

- per feature pick, its command (step 5) as a block the operator can copy, and that the run's questions,
  its three gates (PRD, architecture, plan) and the merge approval come up in the Pane it opens, whose
  `gates` tab clears the session after each approved gate. Ticking Keep Recommended on one of its
  questions puts that run in auto mode: it stops only for questions headed Critical;
- per started task, its Pane and panel and a clickable link (`mcp__pane__links_create`).

Under `--auto`, say that you chose the picks and which ranked candidates you passed over. Mention anything
skipped and why, and repeat the "looks done but open" items if the operator didn't act on them.

## Notes

- Epics are never candidates: they are containers, and their features are what gets built.
- A Pane is costly to create (a worktree, then install and build), so never hand out the command for a
  feature that already has one. Later agents for it (review, fix, QA) are tabs in it.
- The board drifts: tickets stay in Backlog after their PR merged. Trust merged PRs and resolved subtasks
  over the column, but report the drift rather than fixing it silently.
