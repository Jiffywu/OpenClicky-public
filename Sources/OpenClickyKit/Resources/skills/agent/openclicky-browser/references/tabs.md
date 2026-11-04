# Tabs

## Default: your own tab group

`open` creates a background tab beside the user's current one and puts it in a tab group named after this job
(for example "🛒 Weekly groceries"), so the user sees at a glance which tabs are yours and can keep working while
you do. Keep a note of each tab id and what it holds, and pass the id on every call. `tabs` marks the ones this
job opened.

If the browser can't group tabs there, the result says so; the tab still works the same way.

## The user's focused tab

`tabs` lists every open tab and marks the focused one. Work in it only when the job is about the page the user
has open ("summarize this page", "fill in this form"). Snapshot it before you act and change only what was asked.
Calls without a `tabId` go to the focused tab, which is why you should always pass one. You can't close it, and
it is never closed for you.

## Several tabs

Comparing things (prices, flights, documents) works best with one tab per source. Open them one at a time,
`extract` each, and keep your notes in a file in `tmp/` so a long job doesn't depend on remembering every page.
Close a tab with `close {tabId}` once you have what you need from it.

## At the end of your turn

Tabs you opened close by themselves when your turn ends. To leave one open, call `keep` before you finish:

- `keep {tabId, why: "result"}`: the page is the result, or the user should check it (a filled cart, a draft).
- `keep {tabId, why: "waiting"}`: you need it in your next turn (the user is signing in there, a slow export).

Keep lasts one turn: in your next turn, keep it again if you still need it. In your report, name the kept tab by
its title so the user can find it. If the user pressed Stop, nothing is closed: the tabs are theirs.
