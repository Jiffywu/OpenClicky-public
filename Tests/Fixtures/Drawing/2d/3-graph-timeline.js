```js
// Graphs and timelines on paper cards.
step(1)
say("Here is how fast the cache warms up.")
const card = paper(90, 130, 600, 450, { title: "Cache hit rate" })
const g = graph(card.x + 50, card.y + 20, card.w - 110, card.h - 110, { x: [0, 60], y: [0, 100], xLabel: "minutes", yLabel: "% hits", grid: true })
const warm = t => 100 * (1 - Math.exp(-t / 12))
g.plot(warm, { tone: "blue", label: "hits" })
step(2)
say("After twenty five minutes it is nearly full.")
g.point(25, warm(25), { guides: true, label: "88%" })
step(3)
say("And this is when each piece shipped.")
const t = paper(740, 170, 470, 260, { title: "Releases" })
timeline(t.x, t.y + 80, t.w, [[2019, "Cache"], [2021, "Warm-up"], [2024, "Prefetch"]], { alternate: true })
step(4)
say("Want to see where the curve comes from?")
button(t.x, t.y + t.h + 70, "Show me the math")
```
