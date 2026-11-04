# Drawing language: photos, places, quotes and site icons

Real pictures and live data inside a drawing: a photo print, a place card with a small map, a stock card with a
sparkline, and site icons for source credits. The pieces live in `Sources/OpenClickyKit/Resources/js/media-api.js`, a
plugin registered with `__engine.registerModule` like the 3D `figure-api.js`. This file has two parts:

1. **For the model**: the section between the `prompt` markers goes into the brain's instructions after the 2D
   language (`docs/dsl.md`).
2. **For the native side**: the marks, the request/patch hook between engine and host, the lookups and their guards.

---

<!-- prompt:start -->
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
<!-- prompt:end -->

---

## Marks

| `do` | Fields from the program | Fields the host fills in (`state: "ready"`) |
|---|---|---|
| `photo` | `at`, `w`, `h`, `query` (grammar below), `caption`, `subtitle`, `tilt` | `image` (store key), `aspect`, `title`, `credit`, `license`, `provider`, `source` (host), `sourceURL` |
| `place` | `at`, `w`, `h`, `query` | `title` (the place's name), `address`, `category`, `lat`, `lon`, `map` (store key), `mapsURL`, `phone`, `website` |
| `stock` | `at`, `w`, `h`, `symbol`, `range` | `company`, `price`, `change`, `changePercent`, `currency`, `closes` (≤ 60, oldest first), `basis`, `asOf`, `marketOpen` |
| `favicon` | `at`, `w`, `h` (square), `host` | `image` (store key) |
| `image` | `at`, `w`, `h`, `url` (public https), `radius` | `image` (store key), `aspect`, `source` (host), `sourceURL` |

Every media mark also carries `state` (`loading`, `ready` or `failed`, with `reason` when failed) and `ref`, the
request it is waiting for. Its `text` is what the card state text (`describe()`) shows to follow-up turns, and the
plugin keeps it current: a stock card reads `AAPL $231.40 (+1.25%)` once its quote has arrived.

The photo query grammar is the lookup services' (`docs/lookups.md`, from 04 §13.9): `[nopeople:] <name>`,
`[nopeople:] web: <words>`, `[nopeople:] page: <url> :: <name>`. `{people: false}` adds `nopeople:`.

How they are painted (`DrawingPainter+Media.swift`):
- **photo**: a print with a soft shadow and a strip of tape, the picture cropped to fill its well, the caption in the
  hand style, and the source host (and licence when known) in small grey type under the print. Loading shows a grey
  well with "finding a photo…"; failed shows "no photo found".
- **place**: a white card, a MapKit snapshot (or a drawn street placeholder) with a pin, the name in bold and the
  category and address in grey (two lines at most).
- **stock**: ticker and range, company name, price, a green or red change line, and a sparkline over a dashed basis
  line (the previous close for one day, else the first close).
- **favicon**: the site's icon in a small rounded tile.
- **image**: the picture itself, cropped to fill its rounded box; a grey well says "loading image…" or "image
  unavailable".

**Same page once.** A drawing shows each page's preview and each picture address once: a second `photo()` with a page
already used looks its subject up by name instead (or is skipped when it has no name), and a repeated `image()`
address is skipped, each with a warning. `image()` requests (`kind: "image"`, `url`) download through
`DrawingMediaLookups.image(at:)` with the photo guards (public https hosts only, size and type checks).

## The host hook: `request` and `patch`

The engine (`draw-engine.js`) has two small additions for plugins whose marks need data from outside:

- `ctx.request(mark, payload)` (plugin side) emits `{type: "request", ref, mark, …payload}` at once, while the
  statement runs, so the lookup overlaps the voice instead of waiting for the mark's beat. It stamps `mark.ref`. Refs
  (`q1`, `q2`, …) are never reused, so an answer that arrives after the card was replaced can't reach a new mark.
- `__engine.patch(ref, fields)` (host side; `DrawingEngineHost.Command.patch`, `DrawingSession.patch`) merges `fields`
  into that mark. Identity, part and timing keys (`id`, `do`, `part`, `step`, `turn`, `line`, `start`, `duration`,
  `base`, `edit`, `ref`, `name`) can't be patched. Hooks registered with `ctx.onPatch(fn)` then run (`fn(mark, fields)`). If
  the mark is already on screen it is sent again as a changed mark with `edit: "patch"`, at its original moment if
  that is still ahead, otherwise at once; if it is still waiting for its beat, the answer simply rides with it.
- `DrawingEvent.request(ref:mark:json:)` carries the event on the Swift side; `DrawingSession.onEvent` receives it.

The painter rebuilds a patched mark in place, without the fade-out other replaced marks get. A card that is already
visible stays still and only the new content (the photo, the map, the quote) fades in.

## Looking things up (`DrawingMedia.swift`, `DrawingMediaLive.swift`)

- `DrawingMediaRequest` decodes a request; `cacheKey` makes repeated requests share one lookup and one image.
- `DrawingMediaLookups` is the seam: `photo`, `place`, `map`, `quote`, `favicon`. `LiveDrawingMediaLookups` uses
  `LookupServices`: the image-search slot (Brave or Wikimedia Commons, page previews), MapKit places plus an
  `MKMapSnapshotter` map (no key, no location permission), market data (Twelve Data) and the favicon services.
- `DrawingMediaResolver` (main actor) answers a live session: `attach(to: session)` keeps the session's `onEvent`,
  sets `painter.media` to its `DrawingMediaStore`, runs each lookup once, stores images, and calls `session.patch`.
  `cancelAll()` drops lookups when a new turn starts. Failed lookups patch `state: "failed"` with a short reason (a
  missing key says so) and are retried next time; successful answers are cached (64 entries).
- Images never enter JavaScript. They live in `DrawingMediaStore` (64 images), and marks name them by key.

Guards on what gets shown:
- **Public hosts only.** Candidates whose URLs aren't public https (`PublicURL.isPublic`: no private, loopback or
  link-local addresses, no `.local` names, no bare intranet hosts) are skipped before any request. Downloads go
  through `URLSessionTransport.publicWebOnly`, which refuses redirects off the public web, and the final URL is
  checked again.
- **Size and type.** At most 8 MB, `Content-Type` must be an image (or octet-stream), the image header must declare
  at most 50 megapixels, and it is decoded straight to a 1200 px thumbnail on a GCD queue.
- **People.** `{people: false}` (`nopeople:`) drops results whose words name people, checks thumbnails with Vision
  (the lookup services' people filter), and then checks the photo actually downloaded with Vision again; a photo with
  a face or body is skipped for the next candidate. Without `nopeople:` photos may show people; the prompt tells the
  model never to ask for a private person.
- Favicons come from the configured public icon service, falling back to the other one.

## Rehearsals and `occtl draw`

Rehearsals run on a virtual clock, so `DrawingMediaPrefetch.requests(in:)` finds a program's requests first,
`DrawingRehearsalMedia.resolve(_:with:)` answers them (live or fixtures), and the rehearsal patches each answer
`delay` seconds after its request, the way a live answer arrives while the voice talks.

```sh
occtl draw prog.js out.png --media live --services docs/examples/services-brave-images.json   # Brave photos, MapKit
occtl draw prog.js out.png --media live --media-delay 4 --at 3.5    # show the loading state before answers arrive
occtl draw prog.js out.png --media live --fixture-quotes             # live photos and places, made-up quote
occtl draw prog.js out.png --media fixture                           # no network at all
```

The command prints each request and how it was answered (state, provider, source, title, address, price).
