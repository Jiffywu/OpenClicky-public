```js
// A diagram card set over a quiet part of the window: boxes with labels, a labelled arrow, handwriting and a follow-up button.
step(1)
say("This is the Share button, top right.")
callout(1147, 76, "Share", { side: "below-left" })
step(2)
say("Here is what happens when you share.")
const card = paper(560, 300, 580, 380, { title: "Sharing", board: "grid" })
const you = box(card.x + 20, card.y + 30, 160, 86, { label: "You" })
const friend = box(card.x + card.w - 180, card.y + 30, 160, 86, { label: "Friend" })
arrow([you.right + 10, you.cy], [friend.left - 10, friend.cy], { label: "a link" })
step(3)
say("They can view the file, but not edit it.")
write(card.x + 20, card.y + 160, "View only, unless you say so.", { size: 28 })
circle(friend.cx, friend.cy, 100, { tone: "orange", fill: "orange", fillAlpha: 0.12, outline: false })
step(4)
say("Ask me if you want them to edit too.")
button(card.x + 20, card.y + 250, "How do I let them edit?")
```
