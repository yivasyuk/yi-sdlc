# Ticket workflow (shared by `/yi-sdlc:impl-fix`, `/yi-sdlc:impl-change` and `/yi-sdlc:impl-feature`)

These skills take one YouTrack ticket from the board to a merged PR, working in an isolated environment. They
differ in the first half: a fix restores behaviour the docs already promise, a change decides new behaviour
and gets it approved before building, and a feature goes through the full `sdlc:*` pipeline. Everything
else is the same and lives here. Each skill's numbered steps say which section to follow and when, so follow
them in the skill's order. The sections below are reference, not a sequence.

What differs between repos (the tracker project, the environment script, the gates, where tests live, which
docs to keep in sync) lives in the repo's **project profile**, `.claude/yi-sdlc/project.md` in the main clone.
This file points into it as "profile § <section>". Read it right after this file. If the repo has none,
stop before touching YouTrack, git or anything else, and tell the operator the skill needs one, made from
`profile-template.md` next to this file.

This folder has no `SKILL.md`, so it never triggers by itself.

## Contents

- [Which skill owns a ticket](#which-skill-owns-a-ticket)
- [YouTrack](#youtrack)
- [SDLC mode](#sdlc-mode)
- [The isolated environment](#the-isolated-environment)
- [Get the issue ID](#get-the-issue-id)
- [Test levels](#test-levels)
- [Docs sync](#docs-sync)
- [Gates](#gates)
- [Commits](#commits)
- [Review](#review)
- [Manual testing](#manual-testing)
- [PR and ticket update](#pr-and-ticket-update)
- [Ask to merge](#ask-to-merge)
- [After approval](#after-approval)
- [Ticket comments](#ticket-comments)
- [Blocked exit](#blocked-exit)

## Which skill owns a ticket

Decide by what the ticket asks for. The **Type** field is only a hint, because operators file things
loosely.

| The ticket asks to… | Skill | Usual Type |
|---|---|---|
| Restore behaviour that the docs (PRD ACs, `design-spec.md`, ADRs) or plain sense already promise: an error, a wrong value, a crash, a broken flow | `/yi-sdlc:impl-fix` | Bug, Exception |
| Add behaviour or change what the docs promise, or do a chore with a checkable result (a refactor, an upgrade) | `/yi-sdlc:impl-change` | Task, Feature, Usability Problem |
| A new feature, or a change too big for one PR (`/yi-sdlc:impl-change` step 2 graduates it) | `/yi-sdlc:impl-feature` | Feature, Epic |

- Behaviour that **no doc covers** is a change: deciding what is correct there is a product decision.
- A **mixed ticket** ("fix X and add Y") belongs to `/yi-sdlc:impl-change`, which treats the fix as one more AC.
- When the skill you are in doesn't own the ticket, stop before touching YouTrack, git or the environment, and
  tell the operator which command to run instead (`/yi-sdlc:impl-change <id>`). Don't switch skills yourself:
  the operator picked this one, and they may know something the ticket doesn't say.

## YouTrack

- Use the `youtrack` MCP server only. It is logged in as **developer.yivasiuk**, so everything you write
  shows up under that account. That's how the operator tells your actions from theirs.
- The instance is `https://yivasiuk.youtrack.cloud`; an issue's URL is `https://yivasiuk.youtrack.cloud/issue/<id>`.
  The project and its ID format are in profile § Tracker.
- Don't create tags or saved searches. Anything developer.yivasiuk creates is private to it, so the operator
  (`admin`) won't see it. Use the ones that exist.
- The board columns are the **Stage** field. Set it with `update_custom_field`
  (`fieldName: "Stage"`, `value: {"name": "In Progress"}`).

| Stage | Who sets it | Meaning |
|---|---|---|
| Backlog | operator | Captured, not yet clear |
| Ready To Start | operator | Clear enough to hand to `/yi-sdlc:impl-fix`, `/yi-sdlc:impl-change` or `/yi-sdlc:impl-feature` |
| In Progress | **you**, when you start | You are working on it |
| Blocked | **you** | You need the operator; your comment says what |
| In Review | **you**, once the PR is green | Waiting for the operator's merge approval (in `auto`, only until you merge) |
| Test | **you**, after merge, if tagged `manual-qa` | Merged, waiting for the operator's manual check |
| Done | **you**, after merge, otherwise (operator after a manual check) | Finished |

If the issue is already In Review, Test or Done, stop and tell the operator it was handled before. Backlog,
Ready To Start and Blocked are all fine: the operator invoked you on purpose.

## SDLC mode

The ticket's **`sdlc-mode`** field (a single-value enum; read it with `get_issue_custom_fields`) says how much
of the flow the operator hands you. Read it in step 1 of your skill, every run: the operator may have changed
it while the ticket was Blocked.

| `sdlc-mode` | How you work |
|---|---|
| `auto` | The whole flow is yours, **including the merge**. The skill's planned stops (approve the ACs, ask to merge) are skipped. Stop only for a [critical stop](#critical-stops-in-auto) |
| `semi-auto` | The skill as written: autonomous, with its planned stops |
| `developer` | Not for autonomous work: [start an interaction](#developer-mode) instead |
| empty, or a value not listed | `semi-auto`, and say so in your first message, so the operator can set the field |

The field is the operator's standing order for this ticket, so `auto` overrides the skill's planned stops.
An instruction the operator gives you in the session still wins over the field ("stop before merging",
"show me the ACs first").

### Working in auto

Nobody is waiting at the terminal, so what you would have shown at a planned stop goes onto the ticket
instead, where the operator reads it afterwards.

- **Open questions with a defensible best guess don't stop you.** Take the guess and record it as a
  decision. Prefer the option that is smaller, reversible and closest to what the docs already say.
- Keep a list of these **decisions taken in auto**: each with the question, what you chose and why. It goes
  into the technical comment, the PR body and your final message, so every guess is visible and cheap to
  overturn later.
- The planned stops become ticket comments. Your skill says which.
- **Merge only a PR that earned it:** every check green, the review round done, the live re-check passed.
  Merge the normal way (workflow § After approval). Never use `--admin`, never bypass branch protection or a
  required review, and never merge with a red or pending check. If `gh pr merge` refuses, leave the ticket
  In Review and tell the operator why: that is the end of the run, not something to work around.

### Critical stops in auto

Stop and wait for the operator (workflow § Blocked exit, so the question lands on the ticket) when going on
would mean guessing about something that is costly to get wrong or hard to undo:

- The ticket isn't workable, the defect doesn't reproduce, or the skill sends it elsewhere (wrong skill,
  graduates to the full `sdlc` pipeline). These exits are the same in every mode.
- A product decision with **no defensible best guess**: two readings lead to clearly different features,
  and the docs don't pick one.
- Anything that **reverses** a PRD non-goal, an ADR or an earlier decision override.
- A migration that isn't additive, a breaking change to an endpoint's contract, or anything that deletes or
  rewrites data the operator has.
- Anything near money, safety or secrets that the ticket doesn't spell out, including what profile
  § Critical stops lists for this repo.
- CI or the gates stay red after a reasonable fix attempt, or a pre-existing failure on `origin/main`
  blocks the merge.
- The review still finds a correctness problem in the change after the second round.

When in doubt whether a question is critical, ask what a wrong guess would cost after the merge. A wrong
label or layout detail is a one-line follow-up ticket: decide it. Lost data, a wrong trade or a broken
contract is not: stop.

### Developer mode

The operator wants to drive this ticket themselves, with you as a pair, not to have it done for them. Read
the ticket (step 1's reads and the ownership check only) and look at the docs and code it points to. Then,
before changing anything:

1. Don't set the Stage, bring up the environment, create a branch, comment on the ticket or edit files.
2. Give the operator a short brief: what the ticket asks for, where it lives (feature, capability, screen,
   the files you would start from), what is unclear, and how you would approach it, as your skill's steps
   would.
3. Ask how they want to proceed, and end your turn.

From then on it's an ordinary working session. The skill's steps and this workflow are a menu to offer
("bring up the isolated environment?", "write the failing test first?"), not a script. Ask before each
outward action (a Stage change, a ticket comment, a push, a PR, the merge), and follow the operator's lead
when they choose a different route.

## The isolated environment

All work happens in an environment of its own, so the operator's checkout and dev stack stay untouched. They
may be using them while you work. The repo's environment script builds and removes it; profile § Environment
names the script, what the operator's dev stack is, and what `up` gives you. Run the script from the main
clone with the PowerShell tool, always by its absolute path in the main clone (`<main>` below is
`git rev-parse --show-toplevel` there): the worktree has its own copy, which would resolve its paths from the
worktree and build the wrong environment. Below, `ticket-env.ps1` means that absolute path.

Every environment script takes these commands:

| Command | Does |
|---|---|
| `up -Issue <id> -Branch <branch>` | Creates a git worktree on a new branch from `origin/main` (on a re-run, reuses the branch and worktree), gives it whatever it needs to run on its own, and starts the app from it. Prints JSON: the worktree path, the app's URLs, log paths |
| `status -Issue <id>` | Prints the same JSON, plus whether each process is alive |
| `api-restart -Issue <id>` | Rebuilds and restarts what doesn't hot-reload, from the worktree |
| `e2e -Issue <id>` | Runs the end-to-end tests against the isolated environment |
| `down -Issue <id> [-KeepWorktree]` | Stops everything, removes what `up` created, and the worktree (refuses if it has real uncommitted work) |

Branches: `fix/<id>-<short-kebab-slug>` for `/yi-sdlc:impl-fix`, `change/<id>-<short-kebab-slug>` for
`/yi-sdlc:impl-change`, `feature/<id>-<feature-slug>` (or `feature/<id>` for an unnamed feature) for
`/yi-sdlc:impl-feature`.

Rules that follow from it:
- **Edit only inside the worktree** (absolute paths under the printed `worktree`), and run git and the build
  tools there. Never change files in the main clone. That includes docs: every edit from § Docs sync goes in
  the worktree.
- Data the environment copies is a snapshot from `up`. Migrations, loads and deletes you run land in the copy
  only.
- Profile § Environment lists what the isolated app still reaches outside itself (live services, paid APIs)
  and what you must never do there.

## Get the issue ID

The issue ID is mandatory. Which ticket to work on is the operator's choice, never yours.

- An ID in the project's format, or one profile § Tracker says to normalize (another case, an old prefix, a
  bare number): normalize it and use it.
- Anything else, or nothing: ask the question your skill gives ("Which issue should I fix?" or "Which issue
  should I implement?", followed by "Enter its number (e.g. <an example ID from profile § Tracker>).") and end
  your turn. Don't search YouTrack, list the board or pick an issue yourself, even when only one is open.
  Don't touch YouTrack, git or the environment until they answer.

## Test levels

Write the test **before** the production code, run it, and confirm it fails for the reason you expect. Keep
the failing assertion line. A test written after the code tends to test the code, not the requirement.

Pick the lowest level that can show the behaviour, and add higher levels only for what the lower ones can't
reach. One well-placed test beats one of each. Profile § Test levels maps where behaviour lives to the test
level and the test project, and lists the coding conventions, skills and generated-code steps a change must
follow.

Make no drive-by refactors or unrelated cleanups. Note them as suggestions in the technical comment.

## Docs sync

The feature docs are what the next ticket reads to decide what "correct" means, and what a later feature's
design reads about this one. A doc that still describes behaviour that is gone misleads both, so a ticket
isn't done until the docs match the code it ships. (A real case: a ticket removed a button and updated the
PRD, but left it in `sad.md`'s flow, `test-plan.md` and `contracts/openapi.yaml`. This section is what
catches that.)

Feature docs live in `docs/features/<slug>/`. A feature that went the standard route has `spec.md` in place
of `PRD.md` (same §1/§5 layout), and its changelog may be `changelog.md`. Update what the change touches:

| The change touches… | Update |
|---|---|
| Behaviour: new, changed or withdrawn ACs | `PRD.md` / `spec.md` §5, plus a §1 decision override for a changed AC (`/yi-sdlc:impl-change` step 5) |
| The tests of an AC | `test-plan.md`: a row per new AC, edited rows for changed ACs, withdrawn rows marked as such |
| A screen | `design-spec.md` |
| A flow: who calls whom, an error branch, a button or step in it | `sad.md` §6: the sequence diagram and the AC → flow trace table; the C4 relations when an actor's action changes |
| A term | `CONTEXT.md`, and the term table in `sad.md` if it has one |
| An endpoint, request, response or error code | `contracts/openapi.yaml` (the feature's design contract) |
| Schema: a table, column, enum value or index | `data-model.md` |
| An ADR's premise or consequence | one `*Amended by <id> (<date>):* …` line in the ADR. Never rewrite its decision; reversing one is a critical stop, or graduates the change |
| A bug a doc records as known (PRD §8, a release check's known issues) | annotate it `Fixed by <id>` where it is recorded |
| Anything an operator upgrading would notice | the feature changelog (`/yi-sdlc:impl-change` step 12; a fix adds a line only when it is visible or has an operational note) |
| Anything in profile § Docs sync | what it says (the repo's own docs: conventions, gotchas, architecture map, design system, generated contracts) |

Leave dated records as they are: `_review/`, `_verification/`, `_audit/`, `tasks/`, `pr-body.md`,
`idea-brief.md` and `docs/raw-ideas/`. They say what was true on their date. The known-issue annotation
above is the one exception.

**Sweep for leftovers** once the code is final, before the review. List every name the change removed or
renamed: UI labels, buttons and messages, endpoints and parameters, error codes, terms, withdrawn AC IDs.
Search the docs for them, in `docs/features/<slug>` and the repo-wide docs profile § Docs sync names:

```bash
git grep -n -i -E '<name>|<name>|…' -- docs/features/<slug> <the repo-wide docs>
```

Every hit is either updated or a dated record. A change that only adds still checks that its new ACs have
rows in `test-plan.md` and, when they change a flow, in `sad.md`'s trace table. When the change spans
features or alters a contract another feature uses, search all of `docs/features`.

Commit the doc edits with the change they describe, and list the files in the technical comment.

## Gates

All of profile § Gates must pass. Run them in the worktree.

If something fails that your change didn't cause, confirm it also fails on `origin/main`, leave it alone,
and report it. Profile § Gates also says which generated files a build rewrites and which diffs in them are
noise.

## Commits

Ticket work uses the **ticket ID** as the subject prefix, not the `<feature-name>:` from `/yi-sdlc:git-commit`:

```
<id>: Stop fill gaps from failing on an empty range

<what changed and why, wrapped at ~72 chars; mention migrations and
contract changes>
```

Use the present tense and make one logical change per commit.

## Review

Dispatch the **`sdlc:reviewer`** agent (Agent tool, `subagent_type: "sdlc:reviewer"`). Give it the issue ID,
the acceptance criteria your skill names, the worktree path, and the diff range `origin/main...HEAD`.
Stage 1 checks whether the change does what the criteria say. Stage 2 checks quality, conventions and edge
cases. Also give it the doc files you updated and the names from the leftover sweep (§ Docs sync), and ask
it to check that the docs the change touches match the code. A stale doc is a finding like any other.

Then act on its findings without asking the operator. They asked you to accept the recommendations:

- **Apply** every finding that is a fix inside this ticket's scope.
- **Defer** findings that are large or out of scope (a redesign, another capability, anything that would
  need an ADR). List them as follow-ups.

Re-run the gates and commit `<id>: Address review findings`. Run one review round. Run a second only if the
first found a correctness problem in the change itself.

## Manual testing

Manual testing is needed **only** when automated tests can't cover the change: profile § Manual testing
lists what that is in this repo (live services, how something actually looks, timing). Your live check
doesn't count as the operator's manual test. Neither does being able to write scenarios: if the automated
tests cover the change, manual testing isn't needed. This decides whether the issue ends in Test or Done after
the merge.

## PR and ticket update

1. `git push -u origin <branch>` (from the worktree).
2. `gh pr create --base main --title "<id>: <summary>" --body "<body>"`. The body links the ticket URL and
   holds what your skill lists for it, plus the tests, migrations or contract changes, deferred review items,
   and the manual scenarios if they're needed. In `auto`, add the mode and the decisions taken in auto. End
   it with the attribution line from the session's git instructions.
3. Wait for the checks: `gh pr checks <number> --watch`. If CI or E2E fails, fix it, re-run the gates,
   commit, push, and wait again. This is still your job, not the operator's.
4. Post the **business** comment, then the **technical** comment (`add_comment`, Markdown; see
   [Ticket comments](#ticket-comments)).
5. If manual testing is needed: `add_tag` → `manual-qa`.
6. Set Stage → **In Review**.

## Ask to merge

In `auto`, don't ask: once the merge conditions in § SDLC mode hold, go straight to
[After approval](#after-approval). Everything below goes into your final message instead.

Show the operator, compactly:

- the PR URL and its checks (all green)
- the live before/after your skill describes
- the tests that failed before and pass now (names, and the assertion that failed)
- review: findings applied, findings deferred
- manual testing: needed or not, and why
- anything else they should know (a pre-existing failure, a migration)
- that the isolated app is still up at its URL if they want to try it themselves

Ask: **"Merge the PR?"** and wait. If the operator asks for changes, make them, re-run the gates and the
live re-check, commit, push, wait for green checks, update the technical comment if it changed, and ask
again.

## After approval

1. `gh pr merge <number> --squash` (squash-merge, and the remote branch is deleted), unless profile § Commits
   says the repo merges another way.
2. Set Stage → **Test** if the issue is tagged `manual-qa`, otherwise → **Done**.
3. Run `ticket-env.ps1 down -Issue <id>`, then `git branch -D <branch>` in the main clone (it was
   squash-merged, so `-d` would refuse).
4. Tell the operator: merged, the final Stage, and, if it went to Test, what to check by hand. Their own
   checkout is untouched; `git pull` on `main` picks up the change. In `auto`, this message also carries
   the summary from § Ask to merge and the decisions taken in auto.

## Ticket comments

Keep them short and write them for the reader: the business comment for someone who uses the app, the
technical one for someone who will read the code. The first lines differ by skill; the rest is shared.

**Business**

```markdown
**Fixed:** <one or two sentences in product terms: what went wrong for the operator, and what happens now>
  — or, for a change —
**Changed:** <one or two sentences in product terms: what the operator can do now that they couldn't before>

**Where it shows:** Backend: <capability / operation> · UI: <screen> · DB: <tables, or "no change">

**Manual check:**
1. <step>
2. <expected result>

**Manual testing needed:** No — covered by <tests>. / Yes — <why the tests can't cover it>; tagged `manual-qa`.
```

**Technical**

```markdown
**Root cause:** <one or two sentences>                                     ← fix
**Reproduced on the app:** <steps → symptom>. **After the fix:** <same steps → result>.
  — or, for a change —
**Acceptance criteria:** <feature> PRD <AC IDs added>, changed <AC IDs, old → new in a few words>   ← change
**Before:** <steps → today's behaviour>. **After:** <same steps → new behaviour>.

**Changed:**
- Layers / modules: <the parts of the code base the change touches>
- Endpoints: <METHOD /api/…, or none>
- Flow: <the sequence that changed, e.g. "chart → GET candles → gap fill → upsert">
- Migrations: <name, or none>
- Docs: <files updated, or "none needed"; leftover sweep clean>

**Tests:** <added or changed tests, with level>

**Review:** <n> findings applied. Deferred: <items, or none>

**Decisions taken in auto:** <question → choice, why; one line each>          ← auto only

**PR:** <url>
```

## Blocked exit

Use this when the ticket isn't workable, doesn't reproduce, is too big for the skill, or you hit a decision
that isn't yours:

1. `add_comment` with what you found and **numbered questions**, each with your best guess, so the
   operator can answer "1 yes, 2 the second". Mention what you already checked and tried.
2. Set Stage → **Blocked**.
3. If there's work worth keeping, commit it in the worktree as `<id>: WIP <what>`, leave it unpushed, and
   run `ticket-env.ps1 down -Issue <id> -KeepWorktree`. If there's nothing worth keeping (or no environment
   was brought up yet), run `ticket-env.ps1 down -Issue <id>` and `git branch -D <branch>` when they exist.
4. Tell the operator in one short message that it's blocked and why. When they answer on the ticket, they
   set it back to Ready To Start and run the same command again; `up` reuses the branch and worktree.
