---
name: google-tasks
description: How to manage the user's Google Tasks to-dos through their connected Google account (a Google Tasks MCP server, or Google Tasks tools on the composio server). Task lists, adding, completing, rescheduling and moving tasks, subtasks, and the limits of Google Tasks (due dates are days, no assignees, no reminders). Read it before your first Google Tasks call.
---

# Google Tasks

## Where the tools are

Use the Google Tasks server named in the job's "Connected apps" section, or search the `composio` server's tools
for "google tasks" (names start with `GOOGLETASKS_`). If neither is listed, Google Tasks isn't connected.

## Lists and tasks

- List the task lists first and use their ids. "My Tasks" is the default list most people mean.
- Listing tasks leaves out completed and hidden ones unless you ask for them (show completed, show hidden). Ask
  for them when the user wants "everything" or "what I finished".
- Subtasks hang under a parent task: create the parent first, then add children with its id.
- Moving a task to another list means creating it there and removing the original. Ask before removing.

## Dates

Google Tasks stores a due **day**, not a time. If the user gives a time ("Friday at 3"), set the day, keep the
time in the notes, and say that Google Tasks won't remind them at that time. Offer a calendar event if timing
matters.

## Limits

No assignees, no sharing and no notifications. If the user wants someone else to do something, suggest an email
or a shared tool instead.

## Before you report

List the affected tasks again and check titles, due days, completion and their list.
