---
name: google-docs
description: How to read, create and edit the user's Google Docs through their connected Google account (a Google Docs MCP server, or Google Docs tools on the composio server). Finding a doc by URL or title, reading its structure, and inserting text without disturbing what is already there. Read it before your first Google Docs call. Local .docx files are handled with the shell instead.
---

# Google Docs

## Where the tools are

Use the Google Docs server named in the job's "Connected apps" section, or search the `composio` server's tools
for "google docs" (names start with `GOOGLEDOCS_`). If neither is listed, Google Docs isn't connected.

## Finding the document

- From a link: the id is the part after `/document/d/` and before the next `/`.
- By name: search by title (a Drive search tool, if one is offered, is often the quickest). When several docs
  match, list their titles and last-edited dates and pick the obvious one or ask.

## Reading

Fetch the document and work from its structure (headings, paragraphs, tables, lists), not just its plain text.
Note the character indexes of the places you will change.

## Editing

- Add rather than replace. Insert new text at the end or right after a heading you located. Never clear and
  rewrite a document the user didn't ask you to rewrite.
- Index-based edits shift everything after them. When you make several, apply them from the end of the document
  towards the start, or fetch the document again between edits.
- Creating a document: give it a clear title and put the content in with headings, not one long paragraph.
- Changing who can see or edit a document needs the user's yes first.

## Local files

A `.docx`, `.pages` or `.md` file on the Mac isn't a Google Doc. Work on it with the shell (for example `textutil`,
`pandoc` or a Python library installed into `tmp/pylib`), and keep the original unchanged unless asked.

## Before you report

Fetch the document again and check that your text is where it should be and nothing else moved. Give the user the
document's title and link.
