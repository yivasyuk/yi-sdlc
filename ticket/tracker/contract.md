# Tracker contract (shared by the ticket skills)

The ticket skills (`/yi-sdlc:implement-fix`, `/yi-sdlc:implement-change`,
`/yi-sdlc:implement-feature`) never talk to a particular tracker. They work against the abstract tracker below: **roles** for the board's columns, the
**`sdlc-mode`** of a ticket, one **label**, and a handful of **operations**. The plugin ships an adapter
per tracker that carries out the operations through its MCP server:

| Adapter | File (next to this one) | Tracker |
|---|---|---|
| `youtrack` | `youtrack.md` | YouTrack, through a YouTrack MCP server |
| `jira` | `jira.md` | Jira Cloud, through the Atlassian MCP server |

A repo only maps what is particular to it, in profile § Tracker: which adapter and MCP server, the agent
account, the ticket IDs, **the board's columns in order with their roles**, and **where `sdlc-mode` comes
from**. A repo on another tracker can name its own adapter file instead (same shape as the two above).

The workflow and skills write operations as `tracker.<operation>` and columns by role (`tracker.move <id>
in-progress`). Translate each through profile § Tracker and the adapter at the moment you call the tool.
Never write a tracker's own column, field or tag name into a skill or the workflow.

## Roles

A role is what a column means to the skills. Profile § Tracker `columns` lists the board's columns **in
board order, left to right**, and gives a role to the columns the skills need; a column with no role is
one the agent never moves a ticket into (an "Analysis" or "Design" column, say), but it still counts for
the order.

| Role | Required | Who moves a ticket there | Meaning |
|---|---|---|---|
| `in-progress` | yes | **agent**, when it starts the work | The agent is working on it |
| `in-review` | no | **agent**, once the PR is green | Waiting for the operator's merge approval (in `auto`, only until the agent merges). Without it, the ticket stays `in-progress` until the merge |
| `test` | no | **agent**, after the merge, if labelled `manual-qa` | Merged, waiting for the operator's manual check. Without it, such a ticket goes to `merged`, and the comment says the check is still needed |
| `merged` | yes | **agent**, after the merge otherwise | Where a merged PR leaves the ticket: `Done` on a board that ends there, or the first deployment column (`Ready to deploy to QA`) on one that goes on |
| `blocked` | yes | **agent** | The agent needs the operator; its comment says what. Off the line: it can sit anywhere in the order |

The columns before `in-progress` (`Backlog`, `To Do`, …) need no role: they are the operator's. Neither do
the columns after `merged` (deployment stages, QA, UAT, a final `Done`): they belong to whoever deploys
and checks, and the agent never moves a ticket there.

## Taking a ticket

Check the ticket's column in step 1 of every skill, before touching git or the environment.

| The ticket's column is… | The skill… |
|---|---|
| before the **hand-off column** (`in-review` when the board has one, otherwise `merged`) in the order: anything the operator has, `in-progress` itself, a role-less column in between; or the `blocked` column | takes it. The operator invoked the skill on purpose; `in-progress` and `blocked` are re-runs, and their comments and the branch say where the last run stopped |
| the hand-off column or anything after it | stops: tell the operator it was handled before |
| not in profile § Tracker `columns` | stops: name the column and ask the operator to add it to the profile |

Profile § Tracker may narrow this with **take conditions** in prose (for example "only from Ready To
Start", or "never tickets tagged `hold`"). Check them in the same step; a failed condition is a stop with
the reason, not a Blocked exit, because the agent hasn't started.

## Moving a ticket

The agent moves a ticket **forward only**, along the order, and only to the column of the role the step
names:

| Move | When |
|---|---|
| → `in-progress` | The skill starts the work (after the ownership and workability checks; `/yi-sdlc:implement-change` after its size check), also out of `blocked` on a re-run |
| → `blocked` | Workflow § Blocked exit, from any column before the hand-off column |
| `in-progress` → `in-review` | The PR is open and its checks are green. No `in-review` column: no move |
| → `test` or `merged` | Merged (`test` when labelled `manual-qa` and the board has one) |

`blocked` is off the line, so moves into and out of it ignore the order. Every other move goes forward
only: a move that would go backwards (the ticket is already past the target column) isn't made; leave
the ticket where it is and say so. Moving a ticket back, out of `blocked` other than to start a re-run,
or anywhere past `merged` is the operator's. In `developer` mode the agent makes no move without asking first (workflow § Developer
mode). When the tracker refuses a move (a workflow rule, a required field), don't force it another way:
say what it refused and stop.

## SDLC mode

`sdlc-mode` says how much of the flow the operator hands the agent: `auto`, `semi-auto` or `developer`
(workflow § SDLC mode). Profile § Tracker `sdlc_mode` says where a ticket carries it, in one or both ways:

- **a field**: its name, and which of its values means which mode;
- **tags or labels**: which tag means which mode (e.g. `sdlc:auto`, `sdlc:semi-auto`).

Read it from `tracker.read`, every run. When the profile gives both, the field wins over tags. When tags
disagree with each other, take the most guarded mode (`developer`, then `semi-auto`, then `auto`).
**Nothing set, a value or tag the profile doesn't map, or no `sdlc_mode` in the profile: `developer`**,
and the first message says so and which field or tags would change it. A ticket nobody marked for the
agent is a conversation, not a run.

## Type

`type` is only a **hint** for which skill owns the ticket (workflow § Which skill owns a ticket): `fix`,
`change` or `feature`. Profile § Tracker `type` may map the tracker's issue types onto these; without it,
read the ticket's own type name as a hint as it is.

## Labels

| Label | Set by | Meaning |
|---|---|---|
| `manual-qa` | agent | The change needs the operator's manual check after the merge (workflow § Manual testing) |

Use the tag or label profile § Tracker `labels` maps it to. Never create a label, tag, field, column or
saved search that doesn't exist: in many trackers what the agent's account creates is private to it, and
the operator won't see it. If a mapped one is missing, say so and carry on without it (the comment still
says manual testing is needed).

## Operations

| Operation | Gives or does |
|---|---|
| `tracker.read <id>` | Title, description, column, issue type, tags or labels, and the `sdlc_mode` field when the profile names one |
| `tracker.comments <id>` | Every comment in full, oldest first, with its ID and author |
| `tracker.links <id>` | Linked tickets (relation, ID, title, column) |
| `tracker.attachments <id>` | Attachments (name, URL); read the ones that matter (screenshots, logs) |
| `tracker.move <id> <role>` | Moves the ticket to the column with that role, as [Moving a ticket](#moving-a-ticket) allows |
| `tracker.comment <id> <markdown>` | Posts a comment and returns its ID |
| `tracker.update-comment <id> <comment-id> <markdown>` | Replaces a comment's text. When the adapter can't, it posts a new comment instead, headed the same with "(update)", and says so |
| `tracker.label <id> <label>` | Adds a mapped label |
| `tracker.url <id>` | The ticket's web URL, from profile § Tracker `ticket_url` |

"Read the ticket" in a skill means `read`, `comments`, `links` and `attachments` together.

## Rules

- Use only the MCP server profile § Tracker names. It is logged in as the account profile § Tracker
  `account` names. Ideally that is an agent account of its own, so everything the skills write shows up
  under it, and that is how the operator tells the agent's actions from theirs. When it is the operator's
  own account, start every comment with profile § Tracker `comment_prefix` (default `🤖 Claude:`), so the
  agent's comments still stand out.
- Comments are Markdown. When the tracker renders something else, the adapter says how to convert.
- If an operation fails because the mapping is wrong (an unknown column, field or tag), stop before
  anything else changes and name the profile entry to fix. Don't guess another name.
- Ticket IDs follow profile § Tracker `id_pattern`, after its normalization rules.
