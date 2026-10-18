# Jira adapter

Carries out the [tracker contract](contract.md) on Jira Cloud through the Atlassian MCP server (the
remote `https://mcp.atlassian.com/v1/sse`, or a claude.ai connector). Its tools are called
`mcp__<server>__<tool>`, where `<server>` is profile § Tracker `mcp_server` (usually `atlassian`).

Every tool takes `cloudId`: profile § Tracker `cloud_id`, the site's UUID or its URL
(`https://<site>.atlassian.net`). If it isn't set, `getAccessibleAtlassianResources` lists the sites the
agent account can see.

## What the profile maps

- `columns`: the board's **statuses** in board order. A board column that holds several statuses is
  listed as the status the agent should move to; list the others too, with no role, so a ticket in them
  is recognized.
- `sdlc_mode.field`: a single-select custom field (`customfield_<n>`), and/or `sdlc_mode.tags`: Jira
  labels.
- `labels.manual-qa`: a Jira label.

## Operations

| Operation | Tool | Notes |
|---|---|---|
| `read` | `getJiraIssue` | `fields`: `summary`, `description`, `status`, `issuetype`, `labels` and the `sdlc_mode` field ID; `responseContentFormat: "markdown"`. A single-select value is `{ "value": "<name>" }` |
| `comments` | `getJiraIssue` | `fields: ["comment"]`; the comments are in `fields.comment.comments` |
| `links` | `getJiraIssue`, `getJiraIssueRemoteIssueLinks` | `fields: ["issuelinks"]` for linked issues; remote links for the rest |
| `attachments` | `getJiraIssue` | `fields: ["attachment"]` |
| `move` | `getTransitionsForJiraIssue`, then `transitionJiraIssue` | Jira moves a ticket by a workflow transition, not by setting a field. Pick the transition whose `to.name` is the status with that role, and pass its `id`. No such transition from the current status: report the available ones and stop (contract § Moving a ticket) |
| `comment` | `addCommentToJiraIssue` | `contentFormat: "markdown"` |
| `update-comment` | `addCommentToJiraIssue` | With `commentId` of the comment to replace |
| `label` | `editJiraIssue` | `fields: { "labels": [<current labels>, "<label>"] }`: setting `labels` replaces the list, so read it first |
| `url` | none | `ticket_url` with `{id}` filled in, normally `https://<site>.atlassian.net/browse/{id}` |

## Quirks

- A transition can require fields on its screen (a resolution on `Done`). `transitionJiraIssue` takes
  them in `fields`; when it fails on one, name it and stop rather than guessing a value.
- Labels can't contain spaces, and a new label springs into existence when it's set: only set the one
  profile § Tracker maps, so the contract's "never create one" still holds.
- Issue keys are upper case (`ABC-12`); normalize a lower-case ID before calling the tools.
- Team-managed and company-managed projects name the same status differently: map the names the board
  shows.
