# Ticket workflow (shared by `/yi-sdlc:implement-fix`, `/yi-sdlc:implement-change` and `/yi-sdlc:implement-feature`)

These skills take one tracker ticket from the board to a merged PR, working in an isolated environment. They
differ in the first half: a fix restores behaviour the docs already promise, a change decides new behaviour
and gets it approved before building, and a feature goes through the full `yi-sdlc:*` pipeline. Everything
else is the same and lives here. Each skill's numbered steps say which section to follow and when, so follow
them in the skill's order. The sections below are reference, not a sequence.

The rest of the kit sits next to this file:

| File | Holds |
|---|---|
| `workflow.md` (this file) | The flow the three skills share |
| `tracker/contract.md` | The abstract tracker: column roles, `sdlc-mode`, labels, when a ticket can be taken, which moves the agent makes, and the `tracker.<operation>`s the steps call |
| `tracker/<adapter>.md` | How the adapter profile § Tracker names (`youtrack`, `jira`, or a file in the repo) carries out each operation |
| `environment.md` | The interface of the repo's isolated environment script |
| `launcher.md` | Where the ticket's session runs: its own Rider tab, or here when that isn't possible |

What differs between repos (the tracker and its mapping, the branch names, the environment script, the
gates, where tests live, which docs to keep in sync) lives in the repo's **project profile**,
`.claude/yi-sdlc/project.md` in the main clone. These files point into it as "profile § <section>". Read it
right after this file, then `tracker/contract.md` and the adapter it names. If the repo has no profile,
stop before touching the tracker, git or anything else, and tell the operator the skill needs one, made
from `profile-template.md` next to this file.

This folder has no `SKILL.md`, so it never triggers by itself.

## Contents

- [Which skill owns a ticket](#which-skill-owns-a-ticket)
- [Tracker](#tracker)
- [SDLC mode](#sdlc-mode)
- [Branches](#branches)
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

Decide by what the ticket asks for. The `type` (tracker contract § Type) is only a hint, because
operators file things loosely.

| The ticket asks to… | Skill | Usual `type` |
|---|---|---|
| Restore behaviour that the docs (PRD ACs, `design-spec.md`, ADRs) or plain sense already promise: an error, a wrong value, a crash, a broken flow | `/yi-sdlc:implement-fix` | `fix` |
| Add behaviour or change what the docs promise, or do a chore with a checkable result (a refactor, an upgrade) | `/yi-sdlc:implement-change` | `change` |
| A new feature, or a change too big for one PR (`/yi-sdlc:implement-change` step 2 graduates it) | `/yi-sdlc:implement-feature` | `feature` |

- Behaviour that **no doc covers** is a change: deciding what is correct there is a product decision.
- A **mixed ticket** ("fix X and add Y") belongs to `/yi-sdlc:implement-change`, which treats the fix as
  one more AC.
- When the skill you are in doesn't own the ticket, stop before touching the tracker, git or the environment, and
  tell the operator which command to run instead (`/yi-sdlc:implement-change <id>`). Don't switch skills yourself:
  the operator picked this one, and they may know something the ticket doesn't say.

## Tracker

Every tracker call goes through `tracker/contract.md`. The steps say `tracker.read`, `tracker.move <id>
in-progress`, `tracker.comment`; translate each through profile § Tracker and its adapter at the moment you
call the tool. The contract also decides whether the ticket can be taken at all (§ Taking a ticket, step 1
of every skill) and which moves are yours (§ Moving a ticket: forward along the board's column order, or
to `blocked`).

- **Read the ticket** means `tracker.read`, `tracker.comments`, `tracker.links` and `tracker.attachments`
  for `<id>`. Read the comments in full: on a re-run after `blocked`, the operator's answers are there.
- **Check the column** means contract § Taking a ticket, including profile § Tracker's take conditions.
- **The ticket's URL** is `tracker.url <id>`.

## SDLC mode

The ticket's **`sdlc-mode`** says how much of the flow the operator hands you. Where a ticket carries it (a
field, tags, or both) is profile § Tracker `sdlc_mode`, and tracker contract § SDLC mode says how to read
it. Read it in step 1 of your skill, every run: the operator may have changed it while the ticket was
`blocked`.

| `sdlc-mode` | How you work |
|---|---|
| `auto` | The whole flow is yours, **including the merge**. The skill's planned stops (approve the ACs, ask to merge) are skipped. Stop only for a [critical stop](#critical-stops-in-auto) |
| `semi-auto` | The skill as written: autonomous, with its planned stops |
| `developer` | Not for autonomous work: [start an interaction](#developer-mode) instead |
| nothing set, or a value or tag the profile doesn't map | `developer`, and your first message says which field value or tag would hand the ticket over (`semi-auto`, `auto`) |

The mode is the operator's standing order for this ticket, so `auto` overrides the skill's planned stops.
An instruction the operator gives you in the session still wins over it ("stop before merging", "show me
the ACs first", "go ahead on your own" on a `developer` ticket).

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
  where it is and tell the operator why: that is the end of the run, not something to work around.

### Critical stops in auto

Stop and wait for the operator (workflow § Blocked exit, so the question lands on the ticket) when going on
would mean guessing about something that is costly to get wrong or hard to undo:

- The ticket isn't workable, the defect doesn't reproduce, or the skill sends it elsewhere (wrong skill,
  graduates to the full SDLC pipeline). These exits are the same in every mode.
- A product decision with **no defensible best guess**: two readings lead to clearly different features,
  and the docs don't pick one.
- Anything that **reverses** a PRD non-goal, an ADR or an earlier decision override.
- A migration that isn't additive, a breaking change to an endpoint's contract, or anything that deletes or
  rewrites data the operator has.
- Anything near money, safety or secrets that the ticket doesn't spell out, including what profile
  § Critical stops lists for this repo.
- CI or the gates stay red after a reasonable fix attempt, or a pre-existing failure on `origin/<base>`
  blocks the merge.
- The review still finds a correctness problem in the change after the second round.

When in doubt whether a question is critical, ask what a wrong guess would cost after the merge. A wrong
label or layout detail is a one-line follow-up ticket: decide it. Lost data, a wrong trade or a broken
contract is not: stop.

### Developer mode

The operator wants to drive this ticket themselves, with you as a pair, not to have it done for them. Read
the ticket (step 1's reads and the ownership check only) and look at the docs and code it points to. Then,
before changing anything:

1. Don't move the ticket, bring up the environment, create a branch, comment on the ticket or edit files.
2. Give the operator a short brief: what the ticket asks for, where it lives (feature, capability, screen,
   the files you would start from), what is unclear, and how you would approach it, as your skill's steps
   would.
3. Ask how they want to proceed, and end your turn.

From then on it's an ordinary working session. The skill's steps and this workflow are a menu to offer
("bring up the isolated environment?", "write the failing test first?"), not a script. Ask before each
outward action (a ticket move, a ticket comment, a push, a PR, the merge), and follow the operator's lead
when they choose a different route.

## Branches

Branch names come from profile § Branches: one pattern per kind, with `{id}` (the normalized ticket ID) and
`{slug}` (a short kebab-case summary; for `/yi-sdlc:implement-feature`, the feature's slug), and the `base`
branch every branch starts from and every PR targets. A profile without the section gets the defaults
below, and your first message says so.

| Kind | Used by | Default pattern |
|---|---|---|
| `fix` | `/yi-sdlc:implement-fix` | `fix/{id}-{slug}` |
| `change` | `/yi-sdlc:implement-change` | `change/{id}-{slug}` |
| `feature` | `/yi-sdlc:implement-feature`, named feature | `feature/{id}-{slug}` |
| `feature-unnamed` | `/yi-sdlc:implement-feature`, no name | `feature/{id}` |
| `base` | every PR | `main` |

On a re-run the ticket already has a branch: look for it with the kind's pattern, `{slug}` as `*`
(`git branch --list "fix/<id>-*"`), and reuse it. Below, `<branch>` is the ticket's branch, `<base>` the
base branch and `origin/<base>` its remote copy.

## The isolated environment

`environment.md` is the contract: the repo's script, run by its absolute path in the main clone, with
`up`, `status`, `restart` and `down`, plus whatever more profile § Environment lists, and the rules for
working in the worktree. In short: edit only inside the worktree, never touch the operator's checkout or
dev stack, and respect what profile § Environment says must never happen outside the sandbox. Below,
`ticket-env.ps1` means the script's absolute path in the main clone.

Where the session runs, in its own Rider tab or here, is `launcher.md`. Your skill says when to launch:
after step 1's reads and checks, before the ticket moves to `in-progress`. In a tab session, read
launcher.md § In the tab session first: it changes where `<main>` and `<branch>` come from and how `down`
runs.

## Get the issue ID

The issue ID is mandatory. Which ticket to work on is the operator's choice, never yours. A `--here` among
the arguments isn't part of it: it is for `launcher.md`, and the launch prompt leaves it out.

- An ID matching profile § Tracker `id_pattern`, or one its normalization rules cover (another case, an old
  prefix, a bare number): normalize it and use it.
- Anything else, or nothing: ask the question your skill gives ("Which issue should I fix?" or "Which issue
  should I implement?", followed by "Enter its number (e.g. <an example ID from profile § Tracker>).") and end
  your turn. Don't search the tracker, list the board or pick an issue yourself, even when only one is open.
  Don't touch the tracker, git or the environment until they answer.

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
| Behaviour: new, changed or withdrawn ACs | `PRD.md` / `spec.md` §5, plus a §1 decision override for a changed AC (`/yi-sdlc:implement-change` step 5) |
| The tests of an AC | `test-plan.md`: a row per new AC, edited rows for changed ACs, withdrawn rows marked as such |
| A screen | `design-spec.md` |
| A flow: who calls whom, an error branch, a button or step in it | `sad.md` §6: the sequence diagram and the AC → flow trace table; the C4 relations when an actor's action changes |
| A term | `CONTEXT.md`, and the term table in `sad.md` if it has one |
| An endpoint, request, response or error code | `contracts/openapi.yaml` (the feature's design contract) |
| Schema: a table, column, enum value or index | `data-model.md` |
| An ADR's premise or consequence | one `*Amended by <id> (<date>):* …` line in the ADR. Never rewrite its decision; reversing one is a critical stop, or graduates the change |
| A bug a doc records as known (PRD §8, a release check's known issues) | annotate it `Fixed by <id>` where it is recorded |
| Anything an operator upgrading would notice | the feature changelog (`/yi-sdlc:implement-change` step 12; a fix adds a line only when it is visible or has an operational note) |
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

If something fails that your change didn't cause, confirm it also fails on `origin/<base>`, leave it alone,
and report it. Profile § Gates also says which generated files a build rewrites and which diffs in them are
noise.

## Commits

Commit subjects, bodies and PR titles follow `/yi-sdlc:git-commit` (profile § Commits may override it).
Below, `<prefix>` is the subject prefix it gives for `<branch>`, colon included.

## Review

Dispatch the **`yi-sdlc:reviewer`** agent (Agent tool, `subagent_type: "yi-sdlc:reviewer"`). Give it the issue
ID, the acceptance criteria your skill names, the worktree path, and the diff range `origin/<base>...HEAD`.
Its stage 1 checks whether the change does what the criteria say; stage 2 checks quality, conventions and edge
cases. Also give it the doc files you updated and the names from the leftover sweep (§ Docs sync), and ask
it to check that the docs the change touches match the code. A stale doc is a finding like any other.

Then act on its findings without asking the operator. They asked you to accept the recommendations:

- **Apply** every finding that is a fix inside this ticket's scope.
- **Defer** findings that are large or out of scope (a redesign, another capability, anything that would
  need an ADR). List them as follow-ups.

Re-run the gates and commit `<prefix> Address review findings`. Run one review round. Run a second only if the
first found a correctness problem in the change itself.

## Manual testing

Manual testing is needed **only** when automated tests can't cover the change: profile § Manual testing
lists what that is in this repo (live services, how something actually looks, timing). Your live check
doesn't count as the operator's manual test. Neither does being able to write scenarios: if the automated
tests cover the change, manual testing isn't needed. This decides whether the ticket ends in `test` or `merged`
after the merge.

## PR and ticket update

1. `git push -u origin <branch>` (from the worktree).
2. `gh pr create --base <base> --title "<prefix> <summary>" --body "<body>"`. The body links the ticket URL and
   holds what your skill lists for it, plus the tests, migrations or contract changes, deferred review items,
   and the manual scenarios if they're needed. In `auto`, add the mode and the decisions taken in auto. End
   it with the attribution line from the session's git instructions.
3. Wait for the checks: `gh pr checks <number> --watch`. If CI or E2E fails, fix it, re-run the gates,
   commit, push, and wait again. This is still your job, not the operator's.
4. Post the **business** comment, then the **technical** comment (`tracker.comment`, Markdown; see
   [Ticket comments](#ticket-comments)).
5. If manual testing is needed: `tracker.label <id> manual-qa`.
6. `tracker.move <id> in-review` (no move when the board has no `in-review` column; tracker contract § Moving a ticket).

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
2. `tracker.move <id> test` if the ticket has the `manual-qa` label, otherwise `tracker.move <id> merged`.
3. Run `ticket-env.ps1 down -Issue <id>`, then `git branch -D <branch>` in the main clone (it was
   squash-merged, so `-d` would refuse). A tab session does this as launcher.md § In the tab session says.
4. Tell the operator: merged, the final column, and, if it went to `test`, what to check by hand. Their own
   checkout is untouched; `git pull` on `<base>` picks up the change. In `auto`, this message also carries
   the summary from § Ask to merge and the decisions taken in auto.

## Ticket comments

Keep them short and write them for the reader: the business comment for someone who uses the app, the
technical one for someone who will read the code. The first lines differ by skill; the rest is shared.

**Business**

```markdown
**Fixed:** <one or two sentences in product terms: what went wrong for the operator, and what happens now>
  — or, for a change —
**Changed:** <one or two sentences in product terms: what the operator can do now that they couldn't before>

**Where it shows:** <per part of the app, e.g. Backend: <operation> · UI: <screen> · DB: <tables, or "no change">>

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

1. `tracker.comment` with what you found and **numbered questions**, each with your best guess, so the
   operator can answer "1 yes, 2 the second". Mention what you already checked and tried.
2. `tracker.move <id> blocked`.
3. If there's work worth keeping, commit it in the worktree as `<prefix> WIP <what>`, leave it unpushed, and
   run `ticket-env.ps1 down -Issue <id> -KeepWorktree`. If there's nothing worth keeping (or no environment
   was brought up yet), run `ticket-env.ps1 down -Issue <id>` and `git branch -D <branch>` when they exist.
4. Tell the operator in one short message that it's blocked and why. When they answer on the ticket, they
   run the same command again (the skills take a ticket from `blocked`); `up` reuses the branch and
   worktree.
