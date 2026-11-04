# Files, uploads and downloads

## Uploads

The browser tool can't pick files in a file dialog or drop files onto a page. When a job needs an upload:

1. Prepare the file in `output/` with a clear name.
2. Get the page to the point where the file is the only thing missing.
3. Ask the user, in your report, to choose that file on that page (give the full path and the tab's title).

## Downloads

- Public files: fetch the URL yourself with `curl -L -o tmp/<name> <url>` rather than clicking a link.
- Files behind a login: click the download link in the browser. The file lands in the user's Downloads folder
  (usually `~/Downloads`). Find it by name or as the newest file there, copy it into your folder, and leave the
  original where it is.

## Saving what a page shows

Copy the text you need from `extract` into a file in `output/` (Markdown, or CSV for tables), and note the page's
title and URL as the source. When the visual layout matters, or as proof of a change, take
`screenshot {tabId, save: true}`: it captures the visible part of the tab and saves it as
`output/<site>-<date-time>.jpg` in your folder (the result gives the path).
