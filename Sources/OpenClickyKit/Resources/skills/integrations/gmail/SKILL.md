---
name: gmail
description: How to search, read, count, draft and reply to the user's Gmail through their connected Gmail account (a gmail MCP server, or Gmail tools on the composio server). Drafts by default, small pages of headers before full messages, Gmail search operators, and writing replies that sound like the user. Read it before your first Gmail call. Not for Google Calendar, Drive or Docs.
---

# Gmail

## Where the tools are

The job's "Connected apps" section says how Gmail is connected: a server of its own, or the `composio` server.
On `composio`, search its tools for what you need ("gmail search messages", "gmail create draft") and run the
match; Gmail tool names there start with `GMAIL_`. If neither is listed, Gmail isn't connected: say so in your
report.

## Finding mail

- Search with Gmail's own operators: `from:`, `to:`, `subject:`, `has:attachment`, `filename:pdf`, `is:unread`,
  `is:starred`, `label:`, `in:inbox`, `category:primary`, `after:2026/10/01`, `before:`, `newer_than:3d`,
  `older_than:1y`, and quotes for exact phrases. Combine them instead of fetching everything.
- Ask for small pages (10 to 25) of ids, senders, subjects and dates first. Open full messages or threads only for
  the ones that matter.
- "Payload too large" or a cut-off result means the request was too broad: narrow the query, ask for fewer
  results, or fetch headers only.
- Counting: page through the ids and count them. Totals some tools report are estimates; say "about" when you use
  one.

## Writing

- Make a **draft** for anything outgoing unless the user clearly said to send it. Name the recipients and the
  subject in your report so they can find it.
- Replies stay in their thread (pass the thread id) and keep the subject.
- Sending, forwarding, deleting, archiving in bulk, marking many messages read and changing filters all need the
  user's yes first, with the exact recipients or messages named.

## Sounding like the user

Before drafting, read three to five messages the user sent to the same person or of the same kind. Match their
greeting, length, tone and sign-off. Add no facts, promises or dates they didn't give you; leave a clear
placeholder such as `[time?]` instead.

## Before you report

Open the draft (or the sent message) again and check the recipients, subject, body and any attachment. Report
what you checked, not what you meant to write.
