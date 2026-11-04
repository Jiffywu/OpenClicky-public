---
name: hubspot
description: How to search and update the user's HubSpot CRM (contacts, companies, deals, tickets) through their connected HubSpot account (a hubspot MCP server, or HubSpot tools on the composio server). Searches with explicit properties, paging every page before counting or summing, mapping pipeline and stage labels to ids, and logging notes, calls and tasks. Read it before your first HubSpot call.
---

# HubSpot

## Where the tools are

Use the HubSpot server named in the job's "Connected apps" section, or search the `composio` server's tools for
"hubspot" (names start with `HUBSPOT_`). If neither is listed, HubSpot isn't connected.

## Searching

- Name the properties you need (`dealname`, `amount`, `dealstage`, `closedate`, `hubspot_owner_id`); searches
  return only a few by default.
- Filter on the server (stage, owner, dates) rather than fetching everything.

## Counts, sums and reports

Never total or count from a single page. Page through every result (follow the `after` cursor), write the rows
to a file in `tmp/` as you go (JSON lines or CSV), and compute totals with a short script. Say how many records
the numbers cover.

## Labels are not ids

Pipelines, deal stages, owners and association types have internal ids. Look up the pipeline to turn a stage
label like "Contract sent" into its id, and owners to turn names into owner ids, before filtering or writing.

## Writing

- Log notes, calls and tasks against the right record (with the association), and move a deal's stage, when
  the user asked for that.
- Creating or merging contacts, deleting records and bulk updates need the user's yes first.

## Before you report

Read the record again and check the change. Give the user the record's name and link.
