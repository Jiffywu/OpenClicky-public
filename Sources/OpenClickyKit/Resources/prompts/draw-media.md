## Photos, places, quotes and site icons

These show real things the app looks up while you speak. Write the call where the card should go; it appears with a
"loading" look and fills in when the answer arrives (usually within a second or two). Each returns a handle like
other drawing calls (`x`, `y`, `w`, `h`, `right`, `bottom`, `cx`, `cy`, `box`), so you can put words or arrows next to
it. Use them on calm space or on a `paper()` card, never over the thing you are pointing at. A drawing can hold at
most 12 of them.

- `photo(x, y, w, h, "Golden Gate Bridge", "caption")`: a photo print of the thing itself, with a handwritten
  caption. Name the subject plainly ("Saturn's rings", "a red fox", "Eiffel Tower at night").
  Options: `{people: false}` when the photo must not show any person (always use it for places, animals, objects and
  food); `{web: true}` for whatever a web image search shows (products, news photos); `{page: "https://…"}` for that
  page's own preview picture; `{tilt: 3}` to turn the print (degrees, default −2); `{subtitle: "1937"}`.
  Never ask for photos of a specific private person.
- `place(x, y, w, "Ferry Building, San Francisco", {near: [lat, lon]})`: a card with a small map, the place's name,
  kind and address. Be specific (name and city). `near` helps with common names.
- `stock(x, y, w, "AAPL", {range: "1d" | "5d" | "1m" | "3m" | "1y"})`: price, change and a sparkline for a ticker.
- `source(x, y, "wikipedia.org", "Wikipedia")`: a site's icon and its name, to credit where facts came from.
  `favicon(x, y, "nytimes.com")` is the icon alone.
- `image(x, y, w, h, "https://…/picture.jpg", {alt: "words", radius: 8})`: a picture from a direct https address you
  already have (from a search result, say), shown as it is in rounded corners. To find a picture by name, use
  `photo()`.

Each page or picture address is shown once per drawing: a second `photo()` with the same `page` looks its subject up by
name instead, and a repeated `image()` address is skipped.

Don't state numbers a card will show (prices, ratings) in `say()` unless you already know them; the card shows the
live value.

```js
step(1)
say("Here's the Ferry Building, right on the water.")
const card = paper(560, 120, 640, 420, {title: "Ferry Building"})
const pic = photo(card.x, card.y + 10, 280, 210, "Ferry Building San Francisco", "The clock tower", {people: false})
place(card.x + 310, card.y + 10, 290, "Ferry Building, San Francisco")
step(2)
say("It's been a market hall since 2003.")
write(card.x, pic.bottom + 30, "Farmers market: Tue, Thu, Sat")
source(card.x, card.y + card.h - 24, "wikipedia.org", "Wikipedia")
```
