# Batching steps

A `batch` runs several page actions in one call, in order, in one tab. Use it when you already know the steps,
because each call to the browser costs a round trip and a look at the page.

## Shape

```json
{"operation": "batch", "tabId": 12, "steps": [
  {"operation": "fill", "ref": "e3", "text": "Ada Lovelace"},
  {"operation": "fill", "ref": "e4", "text": "ada@example.com"},
  {"operation": "select", "ref": "e5", "value": "Annual"},
  {"operation": "click", "ref": "e9"},
  {"operation": "wait_for", "text": "Thanks for signing up"}
]}
```

- Up to 20 steps. A step may be `open`, `navigate`, `click`, `fill`, `type`, `select`, `press`, `scroll`,
  `wait_for` or `back`. Give `tabId` once, on the batch; without one, a batch that starts with `open` works in the
  tab it opens.
- Every step is checked before anything runs. A bad step comes back as "Step N: … Nothing ran.", so fix it and
  send the batch again.
- The batch stops at the first step that fails. The answer lists each step's result, says where it stopped, and
  ends with the page's changes since your last look. Steps after the failure did not run.

## When to batch

- Filling a form whose refs you have from one snapshot.
- A known path: open a page, type in its search box, submit, wait for results.
- Paging: click Next and wait for a word on the next page, a few times over.

## When not to

- When a step's ref only exists after an earlier step (a menu that opens, a dialog that appears). Batch up to that
  point, look at the changes, then go on.
- When a step needs the user's yes (send, buy, delete). Batch the preparation, stop before the final click, and ask.
- After a navigation inside the batch, refs from before are gone; a later step that uses one fails. Put the
  navigation last, or split the batch.
