---
name: linear
description: How to read and update the user's Linear issues, teams, projects and cycles through their connected Linear account (a linear MCP server, or Linear tools on the composio server). Prefer the typed tools over raw GraphQL, resolve team workflow states and labels, answer what-changed questions with date filters, and write only when asked. Read it before your first Linear call.
---

# Linear

## Where the tools are

Use the Linear server named in the job's "Connected apps" section (Linear's own server is usually called
`linear`), or search the `composio` server's tools for "linear" (names start with `LINEAR_`). If neither is
listed, Linear isn't connected.

## Reading

- Prefer the specific tools (list issues, get issue, list projects) to raw GraphQL; they return tidy fields.
- Each team has its own workflow states (Backlog, Todo, In Progress, Done…) and labels. Look them up for the team
  before filtering or setting them.
- "What changed" questions: filter issues by updated or completed date since the day the user means, then group by
  project or state.

## Writing

- Create and update issues only when the user asked for it. Assigning, mentioning and commenting notify people.
- When creating an issue, set the team, a clear title, a description with the context the user gave, and the
  priority or labels they asked for; leave everything else alone.

## Before you report

Fetch the issue again and check its state, assignee and labels. Give the user the identifier (for example
`WEB-412`) and the link.
