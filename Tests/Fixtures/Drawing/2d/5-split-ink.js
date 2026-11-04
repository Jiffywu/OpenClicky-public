```js
// The same marks over a light half and a dark half of the screen: ink keeps its hue but stays readable.
step(1)
say("Coloured ink adapts to what is under it.")
for (const [x, label] of [[160, "light screen"], [800, "dark screen"]]) {
  text(x, 120, label, { size: 30, style: "title" })
  write(x, 200, "handwriting in the ink", { size: 30 })
  write(x, 260, "yellow words", { size: 30, tone: "yellow" })
  write(x, 320, "grey words", { size: 30, tone: "grey" })
  arrow([x, 420], [x + 300, 420], { label: "an arrow" })
  box(x, 480, 300, 120, { label: "a box", tone: "purple" })
  pill(x, 650, "a pill")
  badge(x + 120, 662, 3)
}
```
