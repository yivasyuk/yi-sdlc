# YouTrack adapter

Carries out the [tracker contract](contract.md) on YouTrack through a YouTrack MCP server (the one in the
example below is `@abdullahtas/youtrack-mcp-server`). Its tools are called `mcp__<server>__<tool>`, where
`<server>` is profile § Tracker `mcp_server`. A repo adds the server to its `.mcp.json`:

```json
{
  "mcpServers": {
    "youtrack": {
      "command": "cmd",
      "args": ["/c", "npx", "-y", "@abdullahtas/youtrack-mcp-server"],
      "env": { "YOUTRACK_URL": "${YOUTRACK_URL}", "YOUTRACK_TOKEN": "${YOUTRACK_TOKEN}" }
    }
  }
}
```

The token belongs to the agent account (profile § Tracker `account`), not to the operator.

## What the profile maps

- `column_field`: the state-type custom field whose values are the Agile board's columns (often `State`
  or `Stage`). `columns` lists its values in board order.
- `sdlc_mode.field`: a custom field (e.g. an enum `sdlc-mode`), and/or `sdlc_mode.tags`: tag names.
- `labels.manual-qa`: a tag.

## Operations

| Operation | Tool | Notes |
|---|---|---|
| `read` | `get_issue`, `get_issue_custom_fields` | The column is the `column_field` value, the type the `Type` field; tags come with the issue |
| `comments` | `get_comments` | |
| `links` | `get_issue_links` | |
| `attachments` | `get_attachments` | |
| `move` | `update_custom_field` | `fieldName`: `column_field`; `value`: `{"name": "<the column with that role>"}` |
| `comment` | `add_comment` | Markdown as is |
| `update-comment` | `update_comment` | |
| `label` | `add_tag` | The tag must exist and be visible to the agent account |
| `url` | none | `ticket_url` with `{id}` filled in, normally `https://<instance>/issue/{id}` |

## Quirks

- Tags and saved searches the agent account creates are private to it: the operator won't see them. Use
  the ones that exist (contract § Labels). For the same reason, `sdlc_mode` tags must be shared tags the
  operator sets, not ones the agent made.
- A state-type field can carry workflow rules that refuse a move. `update_custom_field` then returns the
  rule's message: report it and stop (contract § Moving a ticket).
- Issue IDs are `<project>-<n>`; YouTrack accepts any case, but use the case the project shows, so
  branches and commits match.
