---
name: implement-change
description: >-
  Implement a change ticket (an enhancement, new or changed behaviour, a task; YouTrack, Jira, or any
  tracker the repo's profile maps) end to end by its ID in an isolated environment (its own Pane and
  worktree, which it opens and hands the run to when started outside it): check it fits one PR, write it into the owning feature's acceptance criteria and get the operator's approval, build it test-first,
  review with yi-sdlc:reviewer, demonstrate it on a running copy of the app, open a PR, report back on the
  ticket, and merge after the operator approves. The ticket's sdlc-mode (a field or tags, per the profile)
  sets the autonomy: auto (self-approves the ACs and merges, stops only on critical issues), semi-auto
  (asks at both stops) or developer, the default (briefs the operator and works with them interactively).
  Defects go to /yi-sdlc:implement-fix; work too big for one PR goes to
  /yi-sdlc:implement-feature (the full SDLC pipeline). Needs the repo's .claude/yi-sdlc/project.md.
disable-model-invocation: true
argument-hint: <ticket-id, required>
model: opus
effort: high
---

# Implement a change ticket

Work **autonomously** from reading the ticket to an open, green PR with the ticket updated, with two
planned stops:

1. **After writing the acceptance criteria, before any code.** In a fix, the docs already say what is
   correct. In a change, you are proposing what correct *becomes*, and that is the operator's call. A
   well-built version of the wrong enhancement costs more than a short wait.
2. **Before merging**, as in `/yi-sdlc:implement-fix`.

There is one more stop at the very start if they didn't give an issue ID (step 0). Every other decision
is yours, made from the ticket, the repo docs and its conventions file.

That is the `semi-auto` flow. The ticket's `sdlc-mode` changes it (step 1): `auto` drops both planned
stops, approving its own ACs and merging by itself, and `developer`, also what a ticket nobody marked gets,
turns the run into a brief plus an interactive session.

**Read `${CLAUDE_PLUGIN_ROOT}/ticket/workflow.md` first, then the repo's project profile
(`.claude/yi-sdlc/project.md` in the main clone), then the files the workflow lists (the tracker contract
and the profile's adapter, `environment.md`).** The workflow holds what this skill shares
with `/yi-sdlc:implement-fix`: the tracker, the SDLC mode, branches, the isolated environment, test levels,
gates, commits, review, PR, merge, ticket comments and the Blocked exit. The profile holds what is
particular to this repo. The steps below point into them as "workflow § <section>" and "profile
§ <section>".

This skill sits between two other routes. `/yi-sdlc:implement-fix` handles defects.
`/yi-sdlc:implement-feature` runs the full SDLC pipeline (`yi-sdlc:interview`, `yi-sdlc:write-prd`…) for
new features. This skill handles changes to an existing feature that fit one PR. Step 2 is where a ticket that has outgrown it leaves.

## 0. Get the issue ID

Workflow § Get the issue ID. The arguments are: `$ARGUMENTS`. If you have to ask, ask **"Which issue should
I implement? Enter its number (e.g. <the change example from profile § Tracker>)."** Below, `<id>` is the
normalized ID.

## 1. Read the issue and understand the change

1. Read the ticket (workflow § Tracker). Read the comments in full: on a re-run after `blocked`, the
   operator's answers are there.
2. Check the column (workflow § Tracker).
3. Check that this is a change (workflow § Which skill owns a ticket). If it only asks to restore behaviour
   the docs already promise, stop and tell the operator to run `/yi-sdlc:implement-fix <id>` instead.
4. Read the `sdlc-mode` (workflow § SDLC mode). In `developer`, do the reads in sub-step 6 and the
   split in sub-step 7, then follow workflow § Developer mode instead of sub-step 8 and the steps after
   them; the items and the step 2 size check belong in the brief. In `auto`, a question that would block or
   wait for the operator from here on is a stop only if it is critical (workflow § Critical stops in auto);
   otherwise take your best guess and record it.
5. `<branch>` is profile § Branches `change` (e.g. `change/<id>-chart-enhancements`; workflow
   § Branches).
6. Find the **owning feature**: the `docs/features/<slug>/` whose PRD covers the area the ticket touches
   (the screen, capability or flow). Read its PRD (§1 decision overrides, §3 non-goals, §5 acceptance
   criteria, §8 open questions; a feature that went the standard route has `spec.md` instead, with the same
   sections, and "PRD" below means that file), `design-spec.md`, `sad.md` §6 flows, `test-plan.md`, its
   ADRs, the `CONTEXT.md` glossary, and then the code.
   - If the change spans several features, the owner is the one where most of the new ACs land. Every other
     feature whose ACs change gets a one-line decision override in its PRD §1 that points to the owner.
   - If no feature owns the area (it predates the feature docs), the ACs go into a new
     `docs/changes/<id>.md` in the same AC format. Say so at the spec stop.
7. Split the ticket into **items**: each separate thing it asks for, phrased as behaviour someone could
   check. A ticket like "Chart enhancements" with five bullets is five items. An item you can only half
   understand still goes on the list, with a question and your best guess, for the spec stop.
8. If no item is workable at all (you can't say what any of it means), take the Blocked exit now.

## 2. Check that it fits one PR

The change **graduates** to the full SDLC pipeline if any of these hold:

- It needs what profile § Change scope names as too big for a change (a new module or capability), or an
  area no PRD covers that is bigger than a screen.
- It needs an architecture decision that would clear the ADR bar: hard to reverse, spanning several
  modules, or with real alternatives the operator should weigh.
- It breaks an existing endpoint's contract, or needs a migration that rewrites or drops existing data.
  Additive migrations (new columns, tables, indexes, enum values) are fine.
- It is more than about two days of work, or would need more than one PR to land safely.

If it graduates, take the Blocked exit before bringing up the environment. Question 1 is "Run it through the
full pipeline as feature `<suggested-slug>` (`/yi-sdlc:implement-feature <id>`)?", with which criterion tripped
and why. If only some items are too big, offer the split instead: "Implement items 1–3 here and file item 4
as its own feature?" A borderline case is the same kind of question. This exit applies in `auto` too: how
much of the ticket to build is the operator's scope call, not a guess.

Otherwise `tracker.move <id> in-progress`.

## 3. Bring up the environment

Workflow § The isolated environment, § Bring it up: the ticket's Pane on `<branch>` (step 1.5; the Pane
is named `<id>-<slug>`), then `ticket-env.ps1 up -Issue <id> -Worktree <worktree>`. Keep the Pane's id and
the printed JSON.

When this session isn't in that Pane (you started it from the main clone), this is where it ends: open the
Pane and hand the ticket off to a Claude agent there (workflow § Hand it off to the Pane), with the branch
slug in the prompt's notes so the Pane's session takes the same `<branch>`. That session runs this skill
again from step 0 and does the rest.

## 4. Record today's behaviour

For each item, look at what the isolated app does **today**, the ways profile § Live check gives. The
worktree is still at `origin/<base>`, so this is what the operator is running. Keep the requests and
responses, screenshots and values on screen.

Write it down per item as numbered steps → what happens now. This confirms you found the right place,
catches items that already work (say so at the stop rather than building them), and gives you the steps
you will repeat in step 11 as the before/after. For a chore with no visible behaviour (a refactor, an
upgrade), say what you checked instead.

## 5. Write the change as acceptance criteria

Edit the owning PRD in the worktree. The PRD is what "correct" will mean for the next `/yi-sdlc:implement-fix`, so
the change has to land there, not only in code.

- **New behaviour → new ACs** in §5, numbered after the last one and tagged with the ticket:
  `### AC-23 (US-02, <id>) — happy path (…)`. Match the existing ones: **Given / When / Then**, the same
  vocabulary, concrete values. Include the error and edge cases of the new behaviour as their own ACs, as the
  PRD does for its own. Add a user story (`US-08 (<id>)`) only when no existing one fits.
- **Changed behaviour → edit the AC in place** and add a §1 decision override line: what it said, what it
  says now, why, `(<id>, <date>)`. This is how the PRD already records changes. Never rewrite an AC silently.
- **Removed behaviour →** mark the AC `Withdrawn by <id>: <why>` instead of deleting it, so references from
  other docs, tests and ADRs stay readable.
- `design-spec.md` when the UI changes. `CONTEXT.md` when a term is new or changes meaning: one line with
  the definition plus what it is *not*. `test-plan.md`: a row per new AC saying how it will be tested.
  The rest of the docs the change touches (workflow § Docs sync) wait for the code in step 8.
- What profile § Change scope says belongs in every change's ACs. If the ticket doesn't settle it, it's a
  question for the stop.

Every AC has to be checkable by a test or by the live demo in step 11. If you can't say how you'd check
one, it isn't finished.

Then dispatch **`yi-sdlc:devils-advocate`** (Agent tool, mode A, the ambiguity hunt). Point it at the PRD and
the ticket text, and limit it to the new and changed ACs. Work through each finding. Tighten the AC when
the repo docs answer it. Otherwise turn it into a numbered question with your best guess for the stop.

Commit the docs: `<prefix> Write the acceptance criteria for <change>` (workflow § Commits).

## 6. Stop: approve the acceptance criteria (semi-auto)

In `auto`, approve them yourself, but leave the record the stop would have produced:

1. Go through the open questions. Each one that is critical (workflow § Critical stops in auto) is a
   Blocked exit now, keeping the worktree. Answer every other one with your best guess, tighten the AC to
   match, and add it to the decisions taken in auto.
2. Commit any AC edits (`<prefix> Settle the open questions for <change>`).
3. Post one ticket comment headed **Acceptance criteria (auto-approved)** with the summary below (items →
   AC IDs, changed ACs, items not built, the plan) and the decisions taken so far. It is what the operator
   reads if they want to know what the change was meant to do before the PR shows what it does.
4. Go on to step 7.

On a re-run in `auto`, that comment is the approval. In `semi-auto`, it isn't: if the operator switched
the mode back, show the stop below.

In `semi-auto`, show the operator, compactly:

- each item → its AC IDs with a one-line gist; changed ACs as old → new; items you are *not* building and
  why (already works per step 4, out of scope, split off)
- today's behaviour per item (step 4)
- the plan: layers and modules touched, endpoints, migrations, the test levels, roughly how big
- anything that reverses a PRD non-goal or an earlier decision override
- the open questions, numbered, each with your best guess

Ask: **"Approve these acceptance criteria?"** and wait. If the operator asks for changes, edit the ACs,
commit (`<prefix> Revise the acceptance criteria for <change>`), and ask again. Re-run the ambiguity hunt only
on ACs that changed substantially. If the operator turns it down or wants to think, take the Blocked exit,
keeping the worktree.

On a re-run where the branch already has the AC commit and the ticket shows no approval, show this stop
again before writing code.

## 7. Write the tests first

For each approved AC, write a test at the lowest level that can show it (workflow § Test levels, profile
§ Test levels). It should fail because the behaviour doesn't exist yet; keep the failing line. A test that
passes before any code means the AC already holds or the test doesn't check it. Find out which.

**Existing tests** that assert the old behaviour of a *changed* AC now fail, and that is expected: update
them to the new AC. Keep a list of test → AC; the reviewer and the technical comment need it. Any other
existing test that breaks is a regression, not part of the change. The same goes for snapshot tests: a
changed snapshot is accepted only when an AC explains its diff.

## 8. Implement

Work AC by AC (or in small slices of related ACs): make its tests green, run the unit tests, and commit
(`<prefix> <what this slice adds>`; workflow § Commits). Follow the conventions in profile § Test levels. A
migration you didn't foresee at the stop, or one that isn't additive, is a reason to go back to the
operator, not to push on. In `auto`, an unforeseen additive migration is a decision to record, not a stop; a
non-additive one still stops.

When the last slice is green, bring the rest of the docs in line with the code (workflow § Docs sync): the
`sad.md` flows and trace table, `contracts/openapi.yaml`, `data-model.md`, ADR amendments, the repo-wide
docs from profile § Docs sync, the `test-plan.md` rows of changed and withdrawn ACs. Run the leftover sweep
and keep its list of names for the review. Commit `<prefix> Bring the docs in line with <change>`.

## 9. Gates

Workflow § Gates.

## 10. Review

Workflow § Review. The acceptance criteria are the **approved new and changed ACs** (give their IDs and the
PRD path). Also ask the reviewer to check three things:

- The owning feature's other ACs still hold.
- Every changed existing test traces to a changed AC (give it the list from step 7).
- The docs match the code: the PRD and every other doc in workflow § Docs sync that the change touches,
  with the leftover sweep's names from step 8.

## 11. Demonstrate it on the running app

Now that the code is final, run `ticket-env.ps1 restart -Issue <id>` and repeat **exactly** the steps
from step 4. Each item must now behave as its ACs say, and the flows next to it must still work. If the
change includes a migration, it was applied to the isolated copy on restart and should show nothing odd.

An AC you can't show working sends you back to step 7 with what you learned.

## 12. Record it in the feature changelog

If the owning feature has a `CHANGELOG.md` (or `changelog.md`), add a section under its title, newest first,
in the shape it already uses: `## <id> — <one line>`, then **What**, **Why** (link the ticket and the AC
IDs), **How to use**, and **Operational notes** (migrations and their rollback, config, anything breaking).
Keep it to what an operator upgrading would need. Commit `<prefix> Record the change in the changelog`.

## 13. Decide whether manual testing is needed

Workflow § Manual testing.

## 14. Open the PR and update the ticket

Workflow § PR and ticket update. The PR body lists the ACs added, changed and withdrawn (IDs, with links
to the PRD), the before/after per item from steps 4 and 11, and the existing tests updated and why. The
comments use the **Changed:** and **Acceptance criteria:** variants.

## 15. Stop: ask to merge (semi-auto)

Workflow § Ask to merge. The live before/after is per item: the step 4 steps → today's behaviour, and the
same steps → the new behaviour. In `auto` there is no stop: merge once the conditions in workflow § SDLC
mode hold.

## 16. After approval (or, in auto, after the checks)

Workflow § After approval.
