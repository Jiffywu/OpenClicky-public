```js
// Pointing at things on a (synthetic) app window: regions, callouts, badges, underline, highlighter.
step(1)
say("First, pick the file you want in the sidebar.")
region(62, 112, 196, 330, "Files")
badge(48, 140, 1)
underline(75, 134, 150)
step(2)
say("Then press the blue Share button up here.")
callout(1147, 76, "Share", { side: "below-left" })
badge(1085, 60, 2)
step(3)
say("This line is the one that changed.")
highlight(306, 196, 460, 22)
point(770, 207, "changed")
step(4)
say("That's it. Want the keyboard shortcut?")
button(900, 640, "What's the shortcut?")
```
