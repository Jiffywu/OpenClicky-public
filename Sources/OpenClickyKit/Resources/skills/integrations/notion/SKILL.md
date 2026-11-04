---
name: notion
description: How to search, read, create and update pages and databases in the user's Notion workspace through their connected Notion account (Notion's own MCP server, usually notion, or Notion tools on the composio server). Searching before creating, adding to pages instead of overwriting them, database properties and filters, and asking before changing who can see a page. Read it before your first Notion call.
---

# Notion

## Where the tools are

Use the Notion server named in the job's "Connected apps" section (Notion's own server is usually `notion`), or
search the `composio` server's tools for "notion" (names start with `NOTION_`). If neither is listed, Notion isn't
connected.

## Finding pages

Search before you create: the page or database the user means probably exists. Fetch a page to read its content
and a database to see its properties (columns) and their types.

## Writing

- Add to pages (append a section, insert under a heading) rather than replacing their content.
- New pages go under the parent the user named, or a sensible one you found; say where you put them.
- Database rows: set properties by their exact names and types (select options must already exist unless the
  tool creates them).
- Sharing, publishing to the web and moving pages between teamspaces change who can see them: ask first.

## Before you report

Fetch the page again and check your change. Give the user the page title and link.
