---
name: jira
description: How to search and update the user's Jira issues through their connected Atlassian account (a jira or atlassian MCP server, or Jira tools on the composio server). JQL with paging, approximate counts, turning names into account ids and project keys, transitions, comments and assignment, and remembering that assignees and watchers get email. Read it before your first Jira call.
---

# Jira

## Where the tools are

Use the Jira or Atlassian server named in the job's "Connected apps" section, or search the `composio` server's
tools for "jira" (names start with `JIRA_`). If neither is listed, Jira isn't connected.

## Searching with JQL

- Write JQL for what the user asked: `project = WEB AND status != Done AND assignee = currentUser() ORDER BY
  updated DESC`. Quote values with spaces.
- Page through results (start position and page size, or the next-page token) instead of asking for everything.
- Totals Jira reports can be approximate for large results. Say "about" or count by paging when exactness matters.

## Names and ids

People are account ids, projects are keys (`WEB`), and issue types and fields have ids. Look them up (user
search, project list, field list) before writing; display names are not ids.

## Changing issues

- Status changes go through transitions: list the issue's available transitions and use the matching id.
- Comments may need Atlassian's document format; follow the tool's schema.
- Creating issues, assigning, commenting and transitioning email the assignee and watchers. Do these when the
  user asked for them; otherwise prepare the change and ask.

## Before you report

Fetch the issue again and check status, assignee and fields. Give the user the issue key and link.
