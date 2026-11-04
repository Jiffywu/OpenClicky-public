---
name: salesforce
description: How to query and update the user's Salesforce org through their connected Salesforce account (a salesforce MCP server, or Salesforce tools on the composio server). SOQL with API names, paging long results, date literals and time zones, and limiting writes to what was asked (stage changes, logged calls, tasks, notes, leads). Read it before your first Salesforce call.
---

# Salesforce

## Where the tools are

Use the Salesforce server named in the job's "Connected apps" section, or search the `composio` server's tools
for "salesforce" (names start with `SALESFORCE_`). If neither is listed, Salesforce isn't connected.

## Reading with SOQL

- Use API names, not labels: `Opportunity.StageName`, `Account.Name`; custom fields end in `__c`. Describe the
  object first when you're not sure of a name.
- Select only the fields you need and filter in the query.
- Long results come back in pages: follow the next-records link (query more) until it's done before you count
  or sum.
- Date literals keep queries short: `CloseDate = THIS_QUARTER`, `CreatedDate = LAST_N_DAYS:30`. Date-time fields
  are in UTC; convert to the user's zone when you report times.

## Writing

Write only what the user asked for: move an opportunity's stage, log a call (a Task of type Call), add a task or a
note, create a lead. Updating many records, deleting, converting leads and changing owners need a yes first.

## Before you report

Query the record again and check the fields you changed. Give the user the record's name and link.
