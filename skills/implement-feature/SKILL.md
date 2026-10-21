---
name: implement-feature
description: >-
  Build a feature ticket (YouTrack, Jira, or any tracker the repo's profile maps) through the whole SDLC
  pipeline in an isolated environment (its own worktree): take an optional feature name, then run yi-sdlc:interview,
  write-prd, clarify-prd, architecture-design, sequences, data model, API contract, design spec, tasks, test
  plan, TDD implementation, review, live verification and ship, then open a PR, report back on the ticket,
  and merge after the operator approves. A second argument sets how hard the stages question the operator:
  easy (default), medium or hard. Stops at three gates (PRD, architecture, plan) and before merging;
  resumable, so re-running it picks up at the next unfinished stage. For new features and changes too big for
  one PR; defects go to /yi-sdlc:implement-fix, one-PR changes to /yi-sdlc:implement-change.
  Needs the repo's .claude/yi-sdlc/project.md.
disable-model-invocation: true
argument-hint: <ticket-id, required> [easy|medium|hard] [--stop-at-gates]
model: opus
effort: xhigh
---

# Implement a feature ticket

Take one feature ticket from the board to a merged PR by running the full `yi-sdlc:*` pipeline, stage by
stage, inside the same isolated environment `/yi-sdlc:implement-fix` and
`/yi-sdlc:implement-change` use. The stages do the product and design work and ask the operator their
own questions; this skill picks the stages, feeds them the ticket, keeps them in the worktree, and wraps them in the ticket workflow (board moves, comments,
PR, merge).

The planned stops:

1. **The feature name** (step 2), which the operator may skip.
2. **Three gates** (step 6), where a wrong turn would be expensive to carry further: after the PRD, after
   the architecture, and before any code.
3. **Before merging** (step 10).

Between them the skill runs on its own, apart from the questions the stages themselves ask, which the
questioning hardness (step 0) scales.

The ticket's `sdlc-mode` doesn't apply to this skill (yet): it runs the same way whatever the ticket says,
including the `developer` default. If the ticket sets a mode, say so in one line in your first message.

**Read `${CLAUDE_PLUGIN_ROOT}/ticket/workflow.md` first, then the repo's project profile
(`.claude/yi-sdlc/project.md` in the main clone), then the files the workflow lists (the tracker contract
and the profile's adapter, `environment.md`).** The workflow holds what this skill shares
with `/yi-sdlc:implement-fix` and `/yi-sdlc:implement-change`: the tracker, branches, the isolated
environment, gates, PR, merge, ticket comments and the Blocked exit. The profile holds what is particular to this repo. The
steps below point into them as "workflow § <section>" and "profile § <section>". Workflow § SDLC mode and
§ Developer mode don't apply here.

## 0. Read the arguments

The arguments are: `$ARGUMENTS`.

- **Issue ID** (required): workflow § Get the issue ID. If you have to ask, ask **"Which feature ticket
  should I build? Enter its number (e.g. <the feature example from profile § Tracker>)."** Below, `<id>` is
  the normalized ID.
- **Questioning hardness** (optional): `easy`, `medium` or `hard`, in any position, also as
  `--depth=<level>`. Missing means **`easy`**. Anything else: ask once which of the three they meant. Below,
  `<depth>` is the level.
- **`--stop-at-gates`** (optional): end the session's turn after each approved gate instead of going on to
  the next stage, so it can be cleared and the command re-run with a fresh context (step 6). Whatever
  clears and resumes the session for the operator, such as a Pane watcher, passes it.

`<depth>` is the SDLC depth dial (`interview_depth`): it sets how many questions the Q&A stages ask and
which analyses they run, never what they cover. `easy` decides the reversible calls with defaults and
shows the assumptions to veto; `medium` walks the real decisions; `hard` walks every decision and runs the
full analysis suite (researcher, strategist, analyst, devil's advocate). The operator chose it with this
command, so every stage gets `--depth=<depth>` and doesn't ask for the level again (step 5).

## 1. Read the ticket and check it is a feature

1. Read the ticket (workflow § Tracker). Read the comments in full: on a re-run, the operator's answers
   and the **Feature pipeline** comment (step 5) are there.
2. Check the column (workflow § Tracker).
3. Check who owns it (workflow § Which skill owns a ticket):
   - A defect → stop and tell the operator to run `/yi-sdlc:implement-fix <id>`.
   - A change to an existing feature that clearly fits one PR (none of the `/yi-sdlc:implement-change`
     step 2 graduation criteria holds) → say so and ask **"This looks like one PR. Run
     `/yi-sdlc:implement-change <id>` instead, or go through the full pipeline anyway?"** The full pipeline isn't wrong for it, only heavier,
     and the operator may want the PRD and SAD.
   - A ticket `/yi-sdlc:implement-change` graduated (its Blocked comment proposed a slug) is a feature:
     offer that slug first in step 2.
4. Read enough to know where the feature lands: the roadmap, the architecture map and the product brief
   (profile § Docs), and the neighbouring `docs/features/<slug>/` folders it touches. The stages read these
   in depth; you only need enough to suggest names and brief the interview.

## 2. Stop: ask for the feature name (optional)

Suggest **two or three kebab-case names** from the ticket, in the style of the existing features (profile
§ Docs lists some): short, product-level, no ticket ID. Check that none is already a folder under
`docs/features/` or a branch (`git branch -a --list "*<name>*"`). Ask **"What should the feature be
called?"** with the suggestions as options plus **"No name — use `<id>`"**, and wait. The operator can also
type their own.

This sets `<slug>` and `<branch>` for the rest of the run (the branches with the default
patterns; profile § Branches `feature` and `feature-unnamed` may differ):

| | Named (e.g. `strategy-configurator`) | No name |
|---|---|---|
| `<slug>`: the `docs/features/` folder and the stages' argument | `strategy-configurator` | `<id>` |
| `<branch>` | `feature`: `feature/<id>-strategy-configurator` | `feature-unnamed`: `feature/<id>` |

`<prefix>`, the commit and PR title subject prefix, is what `/yi-sdlc:git-commit` gives for `<branch>`.

On a re-run, these are in the **Feature pipeline** comment and the branch name: don't ask again.

## 3. Bring up the environment and enter it

1. Note the main clone's root (`git rev-parse --show-toplevel`) as `<main>`, and run the environment
   script from profile § Environment by its absolute path under `<main>` (`environment.md` says why).
2. `tracker.move <id> in-progress`.
3. `ticket-env.ps1 up -Issue <id> -Branch <branch>`. Keep the printed JSON. On a re-run, `up` reuses the
   branch and worktree and restarts what isn't running.
4. **Enter the worktree:** `EnterWorktree` with `path` = the printed `worktree`. The `yi-sdlc:*` stages write
   `docs/features/<slug>/…` and run git relative to the working directory, so the session itself has to
   be in the worktree, not only your own edits. Check with `git branch --show-current`.
5. Copy `<main>\.claude\sdlc.local.md` into the worktree's `.claude\` if it exists and isn't there. It is
   git-ignored, so the worktree doesn't have it, and without it the stages fall back to plugin defaults
   (integration tests, models, commit settings) that aren't the operator's.

The rules in workflow § The isolated environment hold for the whole run: the operator's checkout and dev
stack stay untouched, and profile § Environment says what must never happen outside the sandbox.

## 4. Commits

Every commit subject starts with `<prefix>` (step 2), in the present tense, one logical change each. Each
stage commits its own artifacts (`stage_commit: true`); when a stage proposes a subject in another style
(`01: idea-brief for …`, `feat(<slug>): …`), use `<prefix> <what it wrote>` instead. Never push before
step 9.

## 5. Run the pipeline

Run the stages below in order, each with the Skill tool and `<slug>`. Between stages, go straight on,
except at the three gates (step 6).

- **Each stage ends with a handoff block** that says "`/clear`, then run `<next>`". Inside this skill the
  next stage is yours to start, so don't stop there: print the block's *What I did* and *Review before
  continuing* lines (they're the operator's per-stage checklist) and continue. Auto-compaction handles the
  length. If the context gets heavy anyway, the operator can `/clear` at any stage boundary and re-run
  `/yi-sdlc:implement-feature <id> <depth>`; the skill resumes (below). With `--stop-at-gates` the run
  stops for that after each gate by itself (step 6).
- **Pass `--depth=<depth>`** to every stage that takes it. `yi-sdlc:interview` opens with a mandatory depth
  question of its own: tell it in the args that the operator already chose `<depth>` via
  `/yi-sdlc:implement-feature`, and give that as the answer if it still asks.
- **Brief the interview with the ticket**: title, description, comments, links and attachments as the raw
  idea and prior notes. The ticket is the operator's own words; the interview still asks its checkpoint
  questions, but starts from them instead of from nothing.
- **Never answer a stage's question for the operator.** The stages' `AskUserQuestion` checkpoints are the
  data the artifacts are made of. `<depth>` decides how many there are, not whether they're real.

| # | Stage | Run | Done when |
|---|---|---|---|
| 1 | Ideation | `yi-sdlc:interview <slug>` | `idea-brief.md` with `status: Confirmed` |
| 2 | PRD | `yi-sdlc:write-prd <slug>` | `PRD.md` and `.size` |
| 3 | Clarify | `yi-sdlc:clarify-prd <slug>` | every ambiguity resolved or in §8 with an owner |
| — | **Gate 1: the PRD** | step 6 | approval in the **Feature pipeline** comment |
| 4 | Architecture | `yi-sdlc:architecture-design <slug>` | `sad.md` finalized after the critic, its ADRs Accepted |
| 5 | Sequences | `yi-sdlc:complete-sequence-diagrams <slug>` | `sad.md` §6 flows with AC coverage |
| — | **Gate 2: the architecture** | step 6 | approval in the **Feature pipeline** comment |
| 6 | Data model | `yi-sdlc:generate-data-model <slug>` | `data-model.md` + staged `migrations/`. Skip when §5/§6 add no persistence |
| 7 | API contract | `yi-sdlc:api-forge <slug>` | `contracts/openapi.yaml` + `api-sync-report.md`. Skip when the SAD adds or changes no endpoint |
| 8 | Design spec | `yi-sdlc:prepare-design-spec <slug>` | `design-spec.md`. Only when `target_surfaces` includes `web` |
| 9 | Tasks | `yi-sdlc:break-tasks <slug>` | `tasks/tasks.json` + `tracker.md` |
| 10 | Test plan | `yi-sdlc:plan-tests <slug>` | `test-plan.md` |
| — | **Gate 3: the plan, before code** | step 6 | approval in the **Feature pipeline** comment |
| 11 | Implementation | `yi-sdlc:implement-tasks <slug>` | every task done in `tracker.md`, migrations promoted |
| 12 | Review | `yi-sdlc:review-feature <slug>` | `_review/review-<date>.md` shows PASS |
| 13 | Live check | step 7 | |
| 14 | Ship | `yi-sdlc:ship-feature <slug>` (step 8) | `CHANGELOG.md`, `pr-body.md`, roadmap item Shipped |

A skipped stage is a decision: name it and why in the **Feature pipeline** comment, so the next stage (and
the reviewer) knows it was meant.

**Progress lives on the ticket.** After the first stage, post one comment headed **Feature pipeline** with
`<slug>`, `<branch>`, `<depth>`, and the table above as a checklist (done with its commit hash, skipped with
the reason, gates approved, next). After each stage or gate, update that same comment (`tracker.update-comment`)
rather than adding one per stage, so the board shows where the feature is without a pile of comments.

**Resuming.** On a re-run, find the first stage or gate that isn't done: start from the **Feature
pipeline** comment, then confirm against the worktree (the *Done when* column, and
`git log origin/<base>..HEAD`). When they disagree, trust the artifacts and fix the comment. A stage that
stopped half-way (a draft without its critic pass, a `tracker.md` with tasks still open) is re-run, and the
stage itself picks up from what is on disk.

**When a stage refuses or loops back:**

- A stage hard-refuses on a missing input → the stage before it isn't done; go back to it. Don't
  hand-write the missing artifact.
- `review-feature` says CHANGES REQUESTED → run `implement-tasks` for the findings (the loop-back
  variant, no `/clear`), then `review-feature` again. After the second round still not PASS, take the
  Blocked exit with the open findings.
- The operator wants to stop for now (to think, or to answer later) → **pause**, not `blocked`: commit
  what is worth keeping (`<prefix> WIP <what>`), note the open question in the **Feature pipeline**
  comment, `ExitWorktree` with `keep`, and `ticket-env.ps1 down -Issue <id> -KeepWorktree`. The ticket
  stays `in-progress`. Re-running the command picks up there.
- Anything workflow § Blocked exit covers (the ticket isn't workable, a decision isn't yours) → that exit,
  with `ExitWorktree` `keep` before its `down`.

## 6. The gates

At each gate, show the operator a compact summary of what the stages since the last gate decided, ask
**"Continue to <next stage>?"**, and wait. A change goes back to the stage that owns it (an AC →
`clarify-prd` or an edit to the PRD; a decision → `architecture-design`, or `yi-sdlc:decide-adr` for one more
ADR), and every later stage that read it is re-checked; then ask again. Record each approval in the
**Feature pipeline** comment, so a re-run doesn't ask twice.

Every gate also lists what the stages decided on their own (at `easy`, the assumptions ledgers) and
anything that reverses a non-goal, an ADR or a decision override elsewhere in `docs/`.

- **Gate 1, the PRD** (after clarify-prd): the problem in two sentences, the user stories → AC ID ranges,
  the non-goals, the NFRs with their numbers, the size, what was deferred to §8 and who owns it.
- **Gate 2, the architecture** (after the sequences): `target_surfaces`, the modules and layers touched
  (new ones by name), each ADR with its one-line decision, the flows with their error branches, the risks
  from §11.
- **Gate 3, the plan** (after the test plan): the migrations (additive or not), the endpoints added or
  changed, what profile § Change scope says every change must settle (e.g. new agent tools), the task count
  and dependency shape (how many can run in parallel), the test levels from the plan. This is the last stop
  before the long, expensive part.

**With `--stop-at-gates`**, once the approval is in the **Feature pipeline** comment, stop instead of starting
the next stage:

1. Write `%TEMP%\yi-sdlc\<id>-gate.json`:
   `{"skill":"implement-feature","ticket":"<id>","event":"gate-approved","gate":<1|2|3>,"next":"<next stage's skill>"}`.
2. Inside a Pane terminal (`PANE_PANEL_ID` is set), run `runpane report --state ready --summary-file <that
   file>`, so whatever watches the Pane knows the turn ended at a gate and not mid-stage.
3. End the turn with one line: **"Gate <n> approved. Stopped for a fresh context: `/clear`, then send the
   command this run started with again."** The command is the first message of this session, notes and
   all; the re-run resumes at the next stage (step 5) and doesn't ask the gate again.

A change the operator asked for at the gate is not an approval: go back to the owning stage as above, and
stop only once the gate is approved.

## 7. Check it live on the isolated app

After the review passes, run `ticket-env.ps1 restart -Issue <id>` (so what doesn't hot-reload, and the
promoted migrations, reach the isolated copy). Then show that the ACs hold on the running app, not only in
tests, the ways profile § Live check gives:

- `web` in `target_surfaces` → `yi-sdlc:verify-ui <slug>` against the isolated UI URL (not the operator's dev
  one).
- Api behaviour → call the isolated Api with `curl` and keep the request and response.
- Neighbouring flows the feature touches still work.

An AC you can't show working goes back to `implement-tasks` with what you saw. Keep what you saw: it's the
"live check" in the PR body and the ticket comments.

## 8. Ship

Run `yi-sdlc:ship-feature <slug>`, with three adjustments to what it does by default:

- Its final verification is step 7 plus workflow § Gates, so run the gates there, including the end-to-end
  run when profile § Gates calls for it.
- The PR title is `<prefix> <summary>`, not `feat(<slug>): …`.
- It **proposes** the PR command and doesn't push; that stays so, and step 9 opens the PR.

Then bring the repo-wide docs in line (profile § Ship, and workflow § Docs sync, the last rows). Commit
`<prefix> Update <the docs you updated>`, or say there was nothing to update.

## 9. Open the PR and update the ticket

Workflow § PR and ticket update, from the worktree:

- The body is `docs/features/<slug>/pr-body.md` (`gh pr create --body-file`), with the ticket URL at the
  top, the live check from step 7, and the attribution line at the end.
- `gh pr checks <number> --watch`; a red check is still yours to fix.
- Workflow § Manual testing decides `manual-qa`.
- The ticket comments use these first lines (the rest as in workflow § Ticket comments):
  - Business: **New feature:** what the operator can do now, in product terms, one or two sentences.
  - Technical: **Feature docs:** `docs/features/<slug>/` (PRD AC IDs, ADR numbers). **Live check:** the
    steps from step 7 → what happened.
- Update the **Feature pipeline** comment: every stage done, the PR link. `tracker.move <id> in-review`.

## 10. Stop: ask to merge

Workflow § Ask to merge, always (whatever `sdlc-mode` says). The live before/after is the step 7 check:
what the app can do now that it couldn't. Also list the ADRs the feature adds and the migrations, since
those are what's hardest to undo after the merge.

## 11. After approval

Workflow § After approval, with one step first: `ExitWorktree` with `keep` (the session goes back to the
main clone; `down` removes the worktree itself). Then the merge, the board move, `ticket-env.ps1 down -Issue
<id>`, `git branch -D <branch>`. The `ship-feature` roadmap move is already in the merged PR.
