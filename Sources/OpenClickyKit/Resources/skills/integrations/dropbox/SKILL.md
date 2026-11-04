---
name: dropbox
description: How to find, read, save, move and share files in the user's Dropbox through their connected Dropbox account (a dropbox MCP server, or Dropbox tools on the composio server). Dropbox path rules (the root is an empty string), reusing returned ids and paths, handling large files, and treating sharing links as visible to others. Read it before your first Dropbox call.
---

# Dropbox

## Where the tools are

Use the Dropbox server named in the job's "Connected apps" section, or search the `composio` server's tools for
"dropbox" (names start with `DROPBOX_`). If neither is listed, Dropbox isn't connected. A Dropbox folder synced to
the Mac (`~/Dropbox` or `~/Library/CloudStorage/Dropbox`) can also be read with the shell.

## Paths

- The root folder is the empty string `""`, not `/`. Everything else starts with `/`: `/Projects/Plan.pdf`.
- Paths are case-insensitive. Reuse the `id` or `path_display` a listing or search returned rather than retyping.

## Finding and reading

Search by name or content first; list folders when the user names one. Download large files into `tmp/` and work
on them with the shell instead of reading them into your reply.

## Saving and changing

- Upload deliverables to the folder the user named; otherwise ask or use a clearly named new folder.
- Moving and renaming are fine when asked. Deleting needs a yes.
- A sharing link makes the file visible to anyone who has the link. Create one only when the user asked, and say
  so in your report.

## Before you report

Read the file's metadata again (path, size, modified time) and give the user its path or link.
