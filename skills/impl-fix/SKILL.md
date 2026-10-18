---
name: impl-fix
description: >-
  Fix a YouTrack defect end to end by its ID in an isolated environment (its own worktree, in a Rider
  terminal tab named after it): reproduce it on a running copy of the app, pin it with a failing test, fix,
  review with sdlc:reviewer, re-check it live, open a PR, report back on the ticket, and merge after the
  operator approves. The ticket's sdlc-mode field sets the autonomy: auto (merges without asking, stops only
  on critical issues), semi-auto (asks before merging) or developer (briefs the operator and works with them
  interactively). For a defect only: behaviour the docs already promise. New or changed behaviour goes to
  /yi-sdlc:impl-change. Needs the repo's .claude/yi-sdlc/project.md.
disable-model-invocation: true
argument-hint: <youtrack-issue-id, required, e.g. yv-12> [--here]
model: opus
effort: xhigh
---

# Fix a YouTrack issue

Work **autonomously** from reading the ticket to an open, green PR with the ticket updated. There is
exactly one planned stop: **before merging**, show the operator the result and wait for their OK. There is
one more stop at the very start if they didn't give an issue ID (step 0). Every other decision is yours,
made from the ticket, the repo docs and its conventions file. When a decision genuinely isn't yours to make
(missing requirements, a product choice), don't guess: block the ticket and stop. A confident fix of the
wrong thing costs the operator more than a question.

That is the `semi-auto` flow. The ticket's `sdlc-mode` field can change it (step 1): `auto` drops the merge
stop and merges by itself, and `developer` turns the run into a brief plus an interactive session.

**Read `${CLAUDE_PLUGIN_ROOT}/ticket/workflow.md` first, then the repo's project profile
(`.claude/yi-sdlc/project.md` in the main clone).** The workflow holds what this skill shares with
`/yi-sdlc:impl-change`: YouTrack, the SDLC mode, the isolated environment, test levels, gates, commits,
review, PR, merge, ticket comments and the Blocked exit. The profile holds what is particular to this repo.
The steps below point into them as "workflow § <section>" and "profile § <section>".

## 0. Get the issue ID

Workflow § Get the issue ID. The arguments are: `$ARGUMENTS`. If you have to ask, ask **"Which issue should
I fix? Enter its number (e.g. <the fix example from profile § Tracker>)."** Below, `<id>` is the normalized ID.

## 1. Read the issue and decide whether it is workable

1. `get_issue`, `get_issue_custom_fields`, `get_comments`, `get_issue_links`, `get_attachments` for `<id>`.
   Read the comments in full: on a re-run after Blocked, the operator's answers are there.
2. Check the Stage (workflow § YouTrack, below the table).
3. Check that this is a defect (workflow § Which skill owns a ticket). If the ticket asks for new or changed
   behaviour, stop and tell the operator to run `/yi-sdlc:impl-change <id>` instead.
4. Read the `sdlc-mode` field (workflow § SDLC mode). In `developer`, do the reads in sub-step 6, then
   follow workflow § Developer mode instead of sub-steps 7–8 and the steps after them. In `auto`, a question
   that would block from here on is a stop only if it is critical (workflow § Critical stops in auto);
   otherwise take your best guess and record it.
5. Workflow § Rider tab: unless you are the tab session or it says to stay here, launch the ticket in its
   own tab now and end. `<branch>` is `fix/<id>-<short-kebab-slug>` (e.g. `fix/<id>-fill-gaps-error`).
6. Find where the problem lives: the architecture map and ADRs (profile § Docs), and the feature's own docs
   (`docs/features/<slug>/PRD.md` acceptance criteria, or `spec.md` on a feature that went the standard
   route; `design-spec.md`). Those say what "correct" means. Then read the code.
7. The issue is workable when you can state **expected vs actual behaviour** precisely enough to check
   it. If you can't, take the Blocked exit (workflow § Blocked exit) now, before building anything.
8. Set Stage → **In Progress**.

## 2. Bring up the environment

`ticket-env.ps1 up -Issue <id> -Branch <branch>` (step 1.5; workflow § The isolated environment). Keep the
printed JSON.

## 3. Reproduce on the running app

See the bug in the real application before writing any test. It confirms the ticket describes a real
symptom, shows its actual shape (an error code, a log line, a wrong number on screen), and gives you steps
you will re-run at the end as live proof. The worktree is still at `origin/main`, so this is the code the
operator is running.

Use the ways profile § Live check gives: call the isolated Api and keep the request and the response; drive
the isolated UI with a browser tool (Claude in Chrome or Playwright) and keep what you saw (the visible
error, the wrong value, a screenshot); look in the logs for the matching error and trace.

If it doesn't reproduce, try the variations the ticket allows (another input, option or range). If it still
doesn't, take the Blocked exit with what you tried. Don't fix what you can't see.

Write the reproduction down as numbered steps with the observed symptom. You will repeat exactly these in
step 9, and they go into the approval summary and the technical comment.

## 4. Pin it with a failing test

Turn what you saw into a test **before** fixing (workflow § Test levels, profile § Test levels). Confirm it
fails *for the same reason* you saw on the app.

## 5. Fix, and bring the docs in line

Make the smallest change that fixes the **root cause**, following the conventions in profile § Test levels.

A fix restores what the ACs already promise, so they usually stay as they are. Other docs can still be
wrong. Go through workflow § Docs sync; for a fix, these are the usual cases:

- A doc records this bug as known (PRD §8, a release check's known issues): annotate it `Fixed by <id>`.
- The fix adds a migration, an index or an error code: `data-model.md`, `contracts/openapi.yaml`.
- A doc (`sad.md`, `design-spec.md`, `test-plan.md`) describes the wrong behaviour as if it were right:
  correct it to match the AC.
- The AC was ambiguous and the fix settles one reading: tighten its wording, tagged `(<id>)`, without
  changing what it promised. If tightening it does change that, the ticket is a change (workflow § Which
  skill owns a ticket): block and ask.
- The operator would notice the fix after upgrading: one line in the feature changelog.
- You learned a gotcha the next person would trip on: where profile § Docs sync says gotchas go.

If none applies, the technical comment says "Docs: none needed".

## 6. Gates

Workflow § Gates.

## 7. Commit

Workflow § Commits, e.g. `<id>: Stop fill gaps from failing on an empty range`.

## 8. Review

Workflow § Review. The acceptance criteria are the expected behaviour from step 1; the docs check covers
what step 5 updated.

## 9. Re-check on the running app

Now that the code is final, run `ticket-env.ps1 api-restart -Issue <id>` and repeat **exactly** the steps
from step 3. The symptom must be gone, and what sits next to it must still work. If the fix includes a
migration, it was applied to the isolated copy on restart and should show nothing odd.

If the symptom is still there, the fix is incomplete: go back to step 4 with what you learned.

## 10. Decide whether manual testing is needed

Workflow § Manual testing.

## 11. Open the PR and update the ticket

Workflow § PR and ticket update. The PR body says what changed and why, and how the bug was reproduced
and re-checked on the running app. The comments use the **Fixed:** and **Root cause:** variants.

## 12. Stop: ask to merge (semi-auto)

Workflow § Ask to merge. The live before/after is the step 3 steps → the symptom, and the same steps →
the result now. In `auto` there is no stop: merge once the conditions in workflow § SDLC mode hold.

## 13. After approval (or, in auto, after the checks)

Workflow § After approval.
