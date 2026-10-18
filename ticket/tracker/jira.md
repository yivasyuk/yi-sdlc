# Jira adapter

Carries out the [tracker contract](contract.md) on Jira Cloud through the **Atlassian Rovo MCP server**,
Atlassian's own remote MCP server. Its tools are called `mcp__<server>__<tool>`, where `<server>` is
profile § Tracker `mcp_server` (`atlassian` below). Jira Data Center / Server isn't covered: the Rovo MCP
server is Cloud-only.

## Set up the MCP server

Add it once at **user scope**, so every repo can use it (it carries the signed-in account, so it doesn't
belong in a repo's `.mcp.json`):

```powershell
claude mcp add --transport http --scope user atlassian https://mcp.atlassian.com/v2/mcp
```

Then, in a Claude Code session, run `/mcp`, pick `atlassian` and sign in. The browser's OAuth 2.1 flow asks
which Atlassian site to allow. The server acts with that person's existing Jira permissions, so the account
needs browse, transition, comment and edit rights on the project. Check with `claude mcp get atlassian`
(`Status: ✔ Connected`).

| Endpoint | Status |
|---|---|
| `https://mcp.atlassian.com/v2/mcp` | Current (GA since September 2026). Use it for new setups |
| `https://mcp.atlassian.com/v1/mcp/authv2` | v1. Still works; from March 1, 2027 it serves the v2 tools |
| `https://mcp.atlassian.com/v1/sse` | Old SSE transport; switch to one of the above |

**Account.** OAuth signs in as a person, usually the operator: set `account` to that person and
`comment_prefix` (contract § Rules), so the agent's comments stand out. For an account of the agent's own
(and for unattended runs, where nobody can complete OAuth), use an API token: create one for that account
at https://id.atlassian.com/manage-profile/security/api-tokens, keep it in an environment variable, and
pass it as Basic auth, `base64(email:token)`:

```powershell
$auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("agent@example.com:$env:ATLASSIAN_API_TOKEN"))
claude mcp add --transport http --scope user atlassian https://mcp.atlassian.com/v2/mcp --header "Authorization: Basic $auth"
```

PowerShell expands `$auth` before the command runs, so the header lands in `~/.claude.json` as a literal
value. Don't write `${VAR}` into the header for Claude Code to expand later: that expansion is unreliable
for user-scoped servers, and the request then goes out unauthenticated. `~/.claude.json` is private to the
machine; never put the token, or its Base64 form, in a repo's `.mcp.json`. An organization admin may need
to allow API-token access to the Rovo MCP server first.

**Site.** Every tool takes `cloudId`: profile § Tracker `cloud_id`, the site's URL
(`https://<site>.atlassian.net`) or its UUID. `getAccessibleAtlassianResources` lists the sites the account
can reach, with both.

**Toolsets.** v2 groups its tools into toolsets; the adapter needs `read_jira`, `write_jira` and
`search_jira`. When a tool below is missing from the session, the toolset isn't enabled for the
connection: say so and stop, rather than working around it.

## What the profile maps

- `columns`: the board's **statuses** in board order. A board column that holds several statuses is
  listed as the status the agent should move to; list the others too, with no role, so a ticket in them
  is recognized. Workflows often end with deployment stages (`Ready to deploy to QA`, `QA`, `UAT`): the
  first of them is usually `merged`, and the rest need no role. `listJiraIssueTransitions` (v1:
  `getTransitionsForJiraIssue`) on any ticket lists the workflow's statuses with their exact names.
- `account` and `comment_prefix`: see **Account** above.
- `sdlc_mode.field`: a single-select custom field (`customfield_<n>`), and/or `sdlc_mode.tags`: Jira
  labels.
- `labels.manual-qa`: a Jira label.

## Operations

v2 renamed some tools. Use the name the session lists; both are given where they differ.

| Operation | Tool (v2 / v1) | Notes |
|---|---|---|
| `read` | `getJiraIssue` | `fields`: `summary`, `description`, `status`, `issuetype`, `labels` and the `sdlc_mode` field ID; `responseContentFormat: "markdown"`. A single-select value is `{ "value": "<name>" }` |
| `comments` | `getJiraIssue` | `fields: ["comment"]`; the comments are in `fields.comment.comments` |
| `links` | `getJiraIssue`, `getJiraIssueRemoteIssueLinks` | `fields: ["issuelinks"]` for linked issues; remote links for the rest |
| `attachments` | `getJiraIssue`, then `downloadJiraIssueAttachment` (v2 only) | `fields: ["attachment"]` lists them; download the ones that matter. On v1, read what the listing gives |
| `move` | `listJiraIssueTransitions` / `getTransitionsForJiraIssue`, then `transitionJiraIssue` | Jira moves a ticket by a workflow transition, not by setting a field. Pick the transition whose `to.name` is the status with that role, and pass its `id`. No such transition from the current status: report the available ones and stop (contract § Moving a ticket) |
| `comment` | `addOrEditJiraIssueComment` / `addCommentToJiraIssue` | `contentFormat: "markdown"`; the body starts with `comment_prefix` when the profile sets one |
| `update-comment` | `addOrEditJiraIssueComment` / `addCommentToJiraIssue` | With `commentId` of the comment to replace |
| `label` | `editJiraIssue` | `fields: { "labels": [<current labels>, "<label>"] }`: setting `labels` replaces the list, so read it first |
| `url` | none | `ticket_url` with `{id}` filled in, normally `https://<site>.atlassian.net/browse/{id}` |

## Quirks

- A transition's name can differ from its target status (`Ready to deploy` → `Ready to deploy to QA`):
  always match on `to.name`, never on the transition's `name`. On a workflow without global transitions,
  the target may not be reachable in one step from the current status: report it rather than chaining
  transitions through statuses the board doesn't expect.
- A transition can require fields on its screen (a resolution on `Done`). `transitionJiraIssue` takes
  them in `fields`; when it fails on one, name it and stop rather than guessing a value.
- Labels can't contain spaces, and a new label springs into existence when it's set: only set the one
  profile § Tracker maps, so the contract's "never create one" still holds.
- Issue keys are upper case (`ABC-12`); normalize a lower-case ID before calling the tools.
- Team-managed and company-managed projects name the same status differently: map the names the board
  shows.
- Calls use the account's Rovo credits; `getJiraIssue` with a short `fields` list costs less than
  `"*all"`.
