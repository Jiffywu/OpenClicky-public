---
name: clickup
description: How to read and update the user's ClickUp tasks through their connected ClickUp account (a clickup MCP server, or ClickUp tools on the composio server). Resolving workspace, space, folder and list ids, per-list statuses, priority and dates, and writing only what was asked because assignees get notified. Read it before your first ClickUp call.
---

# ClickUp

## Where the tools are

Use the ClickUp server named in the job's "Connected apps" section, or search the `composio` server's tools for
"clickup" (names start with `CLICKUP_`). If neither is listed, ClickUp isn't connected.

## Finding things

ClickUp nests workspace → space → folder → list → task. Resolve ids from the top by listing each level; never
guess an id. Searching tasks by name across a workspace is usually faster than walking every list.

## Fields

- Statuses belong to each list. Read the list's statuses before setting one and use the exact name.
- Priority runs from 1 (urgent) to 4 (low).
- Dates are timestamps in milliseconds. Convert from the user's time zone and say which zone you used.
- Custom fields are set by their id; read the list's fields first.

## Writing

Change only what was asked. Assigning people, mentioning them in comments and changing watched tasks sends them
notifications, so check the names with the user unless they gave them. Deleting tasks or lists needs a yes.

## Before you report

Fetch the task again and check the fields you set. Give the user the task name and link.
