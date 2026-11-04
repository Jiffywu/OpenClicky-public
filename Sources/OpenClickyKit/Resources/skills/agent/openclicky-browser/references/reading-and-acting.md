# Reading pages and acting on them

## Looking at a page

- `snapshot {tabId}`: the tab id, title, URL and the interactive elements (links, buttons, fields, lists,
  checkboxes), each with a ref such as `e12`, its role and its label. On-screen elements come first.
- `extract {tabId}`: the readable text and any tables (as rows), with no refs. The cheapest way to read an
  article, a price list or a statement. `maxChars` (6,000 by default) cuts the text.
- `read {tabId}`: both at once, for a first look at an unfamiliar page.

`query` narrows a snapshot to elements whose text, label or value mention the words you pass. Use it on long
pages instead of looking at everything again: `snapshot {tabId, query: "Download"}`.

Refs belong to the document that is loaded now. After a click that loads another page, after `navigate` or
`back`, snapshot again before using any ref.

## What changed

Every action answers with a change list: `+` lines for elements that appeared, `-` lines for ones that went away
and `~` lines for ones whose label, value or state changed (shown as they are now). A dialog that opened, a new row
in a list, an error message beside a field, a field that took your text: they show up there. "No elements appeared,
went away or changed" after a click usually means it did nothing; look
for a covering banner or a disabled button. When the action navigated, there is no list: snapshot the new page.

## Acting

- `click {tabId, ref}` presses a link, button, checkbox or tab.
- `fill {tabId, ref, text}` sets a field's whole value the way a page's own code expects. It also works on rich
  editors (mail bodies, comment boxes, document editors) and checks the text landed, and on native lists, where
  `text` is the option to choose. `submit: true` presses Enter afterwards.
- `type {tabId, ref, text}` is the older way to enter text: it replaces the value (pass `clear: false` to add to
  it). Prefer `fill`.
- `select {tabId, ref, value}` picks an option in a native list by its visible text or value. Custom drop-downs
  that aren't native lists: click them, look at the change list, then click the option.
- `scroll {tabId, direction}` moves the page (`up`, `down`, `top`, `bottom`); `scroll {tabId, ref}` brings one
  element into view.
- `press {tabId, key}` sends Enter, Tab, Escape, the arrow keys, Page Up/Down, Home, End, Space, Backspace or
  Delete, to the page or to one element (`ref`).
- `back {tabId}` goes one page back in that tab's history.
- `navigate {tabId, url}` loads another address in a tab you already have.

Several of these in a row can go in one `batch` (see `batching.md`).

## Waiting

Use `wait_for` instead of guessing how long something takes:

- `wait_for {tabId, text: "Saved"}`: until that text appears.
- `wait_for {tabId, url: "/checkout"}`: until the address contains that fragment.
- `gone: true` waits for the text or URL to disappear (a spinner, a "Loading…" label).
- With neither, it waits for the page to finish loading. `timeout` is in seconds, at most 120 (default 15).

## Patterns

- **Search boxes:** snapshot with `query` for the box, `fill` with `submit: true`, then `wait_for` a result word.
- **Multi-step forms:** batch one step's fields, check the change list and the values, then go on. Stop before
  the final submit when the result needs the user's yes (see `confirmations.md`).
- **Long lists and tables:** `extract` once, note what you need, scroll down, extract again for the next part.
  Stop as soon as you have the answer; don't read pages you won't use.
- **Pagination:** look for a "Next" link with `query: "Next"`; count pages so you never loop.
- **An element you expect isn't listed:** it may be off screen, inside a closed menu, or covered by a banner.
  Scroll, open the section, or dismiss the banner, then snapshot again with `query`.

## Checking your work

After every change, confirm it on the page itself: the new value in the field, the "Saved" message, the item in
the list. Report what you saw, not what you expected to happen.
