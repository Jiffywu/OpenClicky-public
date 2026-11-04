---
name: outlook
description: How to work with the user's Outlook and Microsoft 365 mail and calendar through their connected account (an outlook MCP server, or Outlook tools on the composio server). Mailbox-wide search with paging, folders and OData filters, drafts by default, and time zones for meetings and calendar holds. Read it before your first Outlook call.
---

# Outlook (Microsoft 365)

## Where the tools are

Use the Outlook server named in the job's "Connected apps" section, or search the `composio` server's tools for
"outlook" (names start with `OUTLOOK_`). If neither is listed, Outlook isn't connected: say so.

## Mail

- Search the whole mailbox rather than one folder unless the user named a folder. List folders first when you
  need one by name; use the id the listing returns.
- Keep responses small: ask only for the fields you need (`$select` such as subject, from, receivedDateTime),
  filter on the server (`$filter=receivedDateTime ge 2026-10-01T00:00:00Z`, `isRead eq false`), and page with
  `$top` and the next-page link instead of one huge request.
- Drafts are the default for anything outgoing. Sending, forwarding, moving many messages and deleting need the
  user's yes first.

## Calendar

- Every time has a zone. Work in the user's zone (check the Mac with `date +%Z` if the job doesn't say) and
  state it in your report: "Tuesday 3 pm London time".
- Look at free/busy or the user's events before proposing a time.
- A **hold** is a tentative event only the user sees: create one when asked to "hold" or "block" time.
- Invitations email every attendee. Prepare the event, then ask before adding attendees or sending updates.

## Not available

Microsoft To Do isn't reachable through this connection. If the user asks for To Do items, say so and offer a
calendar hold or a draft email to themselves instead.

## Before you report

Re-read the draft or the event you created and check names, times, zone and attendees.
