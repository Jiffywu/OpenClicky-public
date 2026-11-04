---
name: github
description: How to use the user's GitHub account through their connected GitHub server (GitHub's MCP server, usually github, or GitHub tools on the composio server). Searching code, issues and pull requests, reading files at a ref, and treating issues, comments, reviews and merges as visible to other people. Read it before your first GitHub call.
---

# GitHub

## Where the tools are

Use the GitHub server named in the job's "Connected apps" section (usually `github`), or search the `composio`
server's tools for "github" (names start with `GITHUB_`). If neither is listed, GitHub isn't connected; the `gh`
command may still work in the shell if the user is signed in there.

## Reading

- Search issues and pull requests with GitHub's qualifiers: `repo:owner/name is:pr is:open author:@me`,
  `label:bug`, `updated:>2026-10-01`.
- Read files at a branch, tag or commit; say which ref you read.
- For a lot of code, clone the repository into `tmp/` and use the shell instead of fetching file by file.

## Writing

Issues, comments, reviews, labels, pull requests and merges are visible to everyone with access and notify
watchers. Do them when the user asked for exactly that; otherwise draft the text in your report and ask. Never
push to or merge into the default branch without an explicit yes.

## Before you report

Fetch what you created or changed and give the user its number and link.
