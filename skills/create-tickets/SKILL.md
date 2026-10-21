---
name: create-tickets
description: >-
  Turn a yi-sdlc repo's docs/roadmap.md into YouTrack tickets: every roadmap step that isn't shipped and has
  no ticket yet becomes an Epic, a Feature or a Task by its size (fog → Epic + recon Task; M → Feature; L/XL →
  Feature or Epic split into feature slugs, which the operator approves), linked parent/subtask and
  depends-on by the roadmap's dependency graph, with the ticket links written back into the roadmap. Warns
  when the roadmap is missing or stale before planning anything. Use it whenever the operator wants roadmap
  steps on the board or in the tracker, asks to file, create, open or sync tickets/issues/epics for the
  roadmap or for a named step ("put backtesting on the board", "make tickets for steps 7 and 8", "what's on
  the roadmap but not in YouTrack"), or to file a ticket for a piece of work in their own words, which it
  checks against the roadmap first ("make a ticket for exporting backtest results to CSV"), even without
  naming the skill. Arguments: steps by number, feature slug or name, or a free-text prompt; --dry-run to
  plan without creating anything.
argument-hint: '[step-number | slug | name ... | "prompt"] [--dry-run]'
---

# Create tracker tickets from the roadmap

The roadmap (`docs/roadmap.md`, kept by `/yi-sdlc:roadmap`) is the plan; the tracker board is where work
gets picked up (`/yi-sdlc:process-tickets`, `/yi-sdlc:implement-feature`, `/yi-sdlc:implement-change`). This skill moves the plan
onto the board: one or more tickets per open roadmap step, shaped so the right pipeline can take each one,
linked so the board shows the same order the roadmap does. Work the roadmap doesn't name gets a warning
before it gets a ticket (step 3b), so the roadmap and the board don't drift apart.

Read `.claude/yi-sdlc/project.md` (the profile) for anything it owns: the tracker project, `ticket_url`,
the board columns (§ Tracker), branch and naming style (§ Branches, § Docs). Don't restate those here.

## 0. Arguments

`$ARGUMENTS` may hold, in any order:

- steps to plan, each named any way the roadmap names it: the step number (`6`, `4b`), the feature slug
  (`backtesting`, `paper-trading`), or the step name, loosely ("news reader", "live trading"). Match a
  slug or name against each step's `slug` and `name` (case-insensitive, hyphens and spaces alike, a clear
  partial match counts). When a name matches several steps or none, show the open steps (number, name,
  slug) and ask which were meant. Without any, plan every open step that has no ticket.
- a free-text prompt, which is one of two things (it can be both):
  - **guidance over roadmap steps**: a selection ("only the trading steps", "everything after
    backtesting") or a steer on the shape ("split step 7 into paper and telegram", "keep 8 as one
    feature"). Resolve the selection to step numbers and confirm them in the plan. A steer settles the
    matching question of step 4 in advance; still say what you'd have recommended if it differs.
  - **a description of work** ("add CSV export of backtest results", "the chart should remember its
    zoom"). Handle it with step 3b.
- `--dry-run` (or "dry run"): do steps 1–6 with reads only, then print the plan and the exact tool calls
  instead of making them. Nothing is created, linked or edited. In a dry run, stale warnings are reported
  but don't stop the run, and every question the run would ask (Feature or Epic, adding a missing
  prerequisite step) is listed with the option you'd recommend, not acted on.

## 1. Scan

From the repo's **main clone** (in a worktree, the main clone is the parent of `git rev-parse
--git-common-dir`), run:

```
python -I ${CLAUDE_PLUGIN_ROOT}/skills/create-tickets/scripts/roadmap_scan.py --repo-root <main clone>
```

It reads the profile, parses the roadmap (steps, the "Not yet specified" fog table, open decisions, the
dependency graph, the shipped table), checks staleness, reads every issue of the tracker project in one
REST call, and prints JSON. It only reads. The parts you use:

- `profile`: `adapter`, `mcp_server`, `project`, `ticket_url`, `column_field`, `columns` (board order),
  `sdlc_mode_field` + `sdlc_mode_values`, `types`.
- `roadmap`: `"missing"`, or `steps` (open ones in full: `num`, `name`, `slug`, `summary`, `source`,
  `size`, `status`, `tickets`, `covered`), `fog`, `decisions`, `edges` (`from` → `to` with `why`, only edges
  into open steps), `updated_at`.
- `stale`, `info`, `warnings`, `uncovered_steps`, `open_issues`, `repo_web` (GitHub blob base for links).
- `field_values`: the values the tracker accepts for `Type`, the column field and the sdlc-mode field.
- `project_id`: the project's internal ID (`0-1`), which `create_issue` needs; the short name is refused.

Stop, saying why, when:

- `profile` is null: this isn't a yi-sdlc ticket repo.
- `profile.adapter` isn't `youtrack`: only the YouTrack adapter is implemented here. Name the adapter.
- `tracker_read` is false: without the board, every step looks uncovered and the run would make
  duplicates. Show `warnings` (token not set, request failed).

## 2. Warn when the roadmap is missing or stale

The tickets are only as good as the roadmap they come from, so check it before planning anything.

- **Missing** (`roadmap == "missing"`): tell the operator there is no `docs/roadmap.md`, suggest
  `/yi-sdlc:roadmap` to write one, and stop. Don't plan from the idea brief or anything else instead.
- **Stale** (`stale` not empty): list every item with what it means. Typical ones:
  - uncommitted roadmap edits, or a roadmap that differs from `origin/main` (as last fetched): tickets
    would describe a plan nobody merged;
  - a step whose tickets are resolved but whose row isn't `shipped`, or the reverse; a `CHANGELOG.md` for
    a step not marked shipped; a shipped step missing from the Shipped table: shipping didn't update the
    roadmap, so "open" may be wrong;
  - a ticket that names a step (its `Roadmap step N` line) the row doesn't link: an earlier run's
    write-back was lost.

  Then ask (AskUserQuestion) **"The roadmap looks stale. Fix it first, or go on?"** with **"Stop: I'll
  update the roadmap first (Recommended)"** and **"Go on with the roadmap as it is"**. On stop, end with
  the list; `/yi-sdlc:roadmap` is the tool to bring it up to date. In `--dry-run`, warn and go on.

`info` (a step whose feature folder already exists, a linked ticket the tracker didn't return) is worth
one line each but isn't a stop.

## 3. Pick the steps

Open steps are those whose status isn't `shipped`. A step is covered when it already has a ticket: linked
in its row or carrying its `Roadmap step N` line. Covered steps get no new tickets; list them with their
tickets in the final report.

Also look through `open_issues` for a ticket that is plainly a roadmap step under another name (same
feature name, same area) but neither links nor is linked. Don't create a second one: propose linking it
instead (the write-back in step 8 adds it to the row, and a comment isn't needed).

If the operator named steps (by number, slug or name, step 0), keep only those. A named step that is shipped or
covered: say so, with its tickets, and skip it.

## 3b. Work the roadmap doesn't name

When the prompt describes work rather than naming steps, place it before making anything:

1. **It is (part of) an open roadmap step.** Say which, and plan that step as usual. If the step is
   already covered, say by which ticket and stop; if it's part of a split Epic, it's that Epic's child.
2. **It changes a shipped feature** and fits one PR (no new capability folder; the profile's § Change
   scope has the test). That is a **Task**, not a roadmap row: summary in the operator's words, a
   description of the change, a Relates link to the shipped feature's ticket when one exists, and no
   `Roadmap step` marker. The roadmap needn't change.
3. **It is a new feature or area the roadmap doesn't have.** Warn: **"The roadmap doesn't have this:
   `<work>`. A new feature should be a roadmap step first, so its size, order and dependencies are
   decided."** Ask: **"Add it to the roadmap first with `/yi-sdlc:roadmap` (Recommended)"**, **"File
   it anyway as a <Feature/Epic> without a roadmap step"**, **"Cancel"**. Filed anyway, it gets no
   marker and no write-back, and the report repeats that the roadmap misses it.
4. **It is a defect.** Not this skill's work: a Bug is filed for `/yi-sdlc:implement-fix`. Say so and stop.

## 4. Choose the ticket shape for each step

| Roadmap size | Ticket type | What it is | Pipeline |
|---|---|---|---|
| fog | **Epic** | A placeholder for an area nobody has sized yet. Its first child is a recon **Task** (the fog table's "How it gets sharpened") | none until recon |
| L / XL that splits into ≥2 feature slugs | **Epic** | A roadmap step made of several deliverables, each with its own PRD, branch and PR | runs through its children (one **Feature** each) |
| M, or an L that ships as one slug | **Feature** | One roadmap row = one `docs/features/<slug>/` = one feature branch = one PR | `/yi-sdlc:implement-feature` |
| XS / S | **Task** | A change to a shipped feature. Not normally a roadmap row; if one appears, it's a Task related to that feature's ticket | `/yi-sdlc:implement-change` |
| defect | **Bug** | Never from the roadmap | `/yi-sdlc:implement-fix` |

Two rules keep this from drifting:

- **A Task becomes a Feature when it needs a new capability folder** (e.g. a new
  `Application/<Capability>/`; the profile's § Change scope states the test). Apply the same test when you
  size an XS/S row.
- **`break-tasks` output never becomes tickets.** Those tasks take a day or less and `implement-tasks`
  tracks them in `tasks.json`/`tracker.md`; copying them to the tracker would duplicate state the agent
  already keeps.

### L / XL: Feature or Epic is the operator's call

Propose one, with the reason, and ask. Read the step's summary, its zone in the roadmap's "Execution path"
table, the decisions that block it, and the neighbouring `docs/features/` folders. Lean to an **Epic**
when the step bundles deliverables that are each useful on their own and could merge separately: two or
more new capability folders, an "X & Y" title, or an open decision that blocks only part of it (the
unblocked part can ship first). Lean to one **Feature** when the parts only work together, or splitting
would leave a child that can't be tested alone.

For an Epic, name the children: kebab-case, product-level, no ticket ID, in the style of the existing
feature folders. Check that none is already a folder under `docs/features/` or a branch (`git branch -a
--list "*<name>*"`). Keep the roadmap's own slug for the child closest to it.

Ask all L/XL steps in one AskUserQuestion (up to 4 questions per call), one question per step, e.g.
**"Step 7 Paper trading & Telegram control (L): one Feature or an Epic?"** with options like
**"Epic: `paper-trading` + `telegram-control` (Recommended)"** (each child explained in the description)
and **"Feature: `paper-trading`"**. The operator can type a different split.

### Fog

An Epic named after the step, plus one recon Task as its subtask: "Recon: <fog area>", carrying what
we'd have to learn and how it gets sharpened. A fog step that the fog table says is sharpened by
something that isn't done yet ("Step 4 shipped and used, then decision D4") still gets its recon Task;
the description says what it waits for.

## 5. Relations

Give each step one **representative** ticket: its Epic, or its single Feature. Then:

- **Parent/subtask:** each Epic is parent for its children (the Features of a split L, the recon Task of
  a fog step).
- **Depends on:** for each graph edge `A → B` where B gets a ticket in this run, B's representative
  depends on A's representative, when A isn't shipped and has a ticket (existing or created now). A
  shipped A needs no link; the description names it. An open A with no ticket and not in this run: the
  description names it ("step 7, no ticket yet"), and the plan offers to add A to the run so the link can
  be made.
- **Backfill the other direction:** for each edge `A → B` where A gets a ticket now and B is open and
  already has one, B's representative depends on A's new ticket. Otherwise a step filed before its
  prerequisite would never be linked to it. Inside a split Epic, link a child to a sibling only
  when it really needs the sibling first (say why in the plan).
- **Open decisions** that block a step (`decisions[].blocks`) are questions for the human owner, not
  pipeline work: they go into the description, not into tickets.
- Don't add Relates links except an XS/S Task to the feature it changes.

## 6. Write the tickets

**Summary:** the step's name for an Epic or a single Feature ("Backtesting tool"); a child Feature's own
short name ("Telegram control"); "Recon: <area>" for a recon Task.

**Description** (Markdown, English). The first line is the marker the next run uses to know a step is
covered, so keep it exact: `Roadmap step <num>`. Links in the roadmap are relative to `docs/`; turn them
into `<repo_web>/docs/<path>` links.

```markdown
Roadmap step <num> · size <size> · [roadmap](<repo_web>/docs/roadmap.md)

<the step's summary, as the roadmap words it; for a child, the part of it this child delivers>

**Feature name:** `<slug>`                      (Feature only: /yi-sdlc:implement-feature offers it first)
**Source:** <the Source cell, links absolute>
**Depends on:** step 5 Bot configurator (shipped), step 6 Backtesting tool (yv-N) — <edge why>
**Blocked by decisions:** D2 — <question> (owner: human)      (only when some block it)
**Pipeline:** /yi-sdlc:implement-feature on this ticket (Feature) · runs through its children (Epic) · none until recon (fog)
```

A recon Task replaces the summary with **What we'd have to learn:** and **How it gets sharpened:** from
the fog table, and ends with: the outcome is a sized row in the roadmap (`/yi-sdlc:roadmap`), after which
this skill runs again for the step.

**Fields:** `Type` is Epic, Feature or Task. Check each against `profile.types` (the `feature` and
`change` lists) and every value you will set (type, column, sdlc-mode) against `field_values`, before
showing the plan: a value missing from either is a stop that names the profile entry or tracker value to
fix, rather than a half-made set of tickets. The column
field (`profile.column_field`) is the first of `profile.columns` (the operator's intake column, e.g.
Backlog). The sdlc-mode field (`profile.sdlc_mode_field`) is set by type, the operator's rule:

| Type | sdlc-mode | Why |
|---|---|---|
| Task | `auto` | small and bounded: the agent may run it end to end |
| Recon Task (child of a fog Epic) | `semi-auto` | the agent researches, but recon ends in the operator's decision (a D-question, real samples), so it stops for them |
| Feature | `semi-auto` | the agent runs the pipeline, the operator answers its stops |
| Epic | `developer` | a container: nothing should run it |

Translate each through `profile.sdlc_mode_values`. Don't set the assignee: the project's defaults may fill
it in (e.g. with the agent account), and that is fine.

## 7. Show the plan and ask

Print one table, in creation order:

| # | Ticket | Type | sdlc-mode | Parent | Depends on | Step |
|---|---|---|---|---|---|---|
| 1 | Backtesting tool | Feature | semi-auto | | (step 5 shipped) | 6 |
| 2 | Paper trading & Telegram control | Epic | developer | | #1 | 7 |
| 3 | Paper trading | Feature | semi-auto | #2 | | 7 |

Under it: the steps skipped as covered (with their tickets), any existing ticket you propose to link
instead of creating, and the roadmap rows the write-back will touch. Then ask **"Create these N
tickets?"**: **"Create them (Recommended)"**, **"Change something"** (take the change, show the plan
again), **"Cancel"**.

In `--dry-run`, print the plan and, in order, the exact tool calls you would make (step 8), then stop.

## 8. Create, link, write back

Use the MCP server `profile.mcp_server` (`mcp__<server>__<tool>`). Create parents before children, then
add every link once all tickets exist.

1. **Create** with `create_issue` (`project`: `project_id` from the scan; the short name gives "Invalid
   structure of entity id"):

   ```json
   "customFields": [
     {"name": "Type",      "$type": "SingleEnumIssueCustomField", "value": {"name": "Feature"}},
     {"name": "Stage",     "$type": "StateIssueCustomField",      "value": {"name": "Backlog"}},
     {"name": "sdlc-mode", "$type": "SingleEnumIssueCustomField", "value": {"name": "semi-auto"}}
   ]
   ```

   (`Stage` and `sdlc-mode` are the profile's field names.) If the tracker refuses a field or value,
   stop: report what was created so far and what it refused. Don't retry with another name, and never
   create a type, field, value or tag: what the agent account creates is private to it.

2. **Link** with `link_issues`. It runs the YouTrack command `<linkType> <targetIssueId>` on `issueId`,
   so the source is the ticket the phrase is about:
   - child of an Epic: `issueId` child, `linkType` `subtask of`, `targetIssueId` the Epic;
   - B depends on A: `issueId` B, `linkType` `depends on`, `targetIssueId` A.

   After the first link of each kind, read it back with `get_issue_links` and check the direction. If
   it's reversed, remove nothing yourself: report it and stop.

3. **Write back** to `docs/roadmap.md`: append each step's representative ticket to its row's **Source**
   cell as `[<id>](<ticket_url>)`, after what's there (`…, [yv-12](https://…/issue/yv-12)`), and set the
   frontmatter `updated_at` to today. A ticket you linked instead of creating gets the same. Touch nothing
   else. Leave the edit uncommitted and say so: the operator commits it with the roadmap's next change.

## 9. Report

- The tickets created: ID, summary, type, sdlc-mode, parent, depends-on, each with its URL
  (`profile.ticket_url`).
- The steps skipped and why (shipped, covered by which tickets, not named in the arguments).
- The stale warnings the operator chose to go past, if any.
- What to run next: `/yi-sdlc:implement-feature <id>` for a Feature that's ready (its dependencies shipped),
  the recon for a fog Epic, `/yi-sdlc:process-tickets` to see the board ranked.
