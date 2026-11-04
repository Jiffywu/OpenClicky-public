# Lookup services

HeyClicky gets web search, photos, places and stock quotes from its own server (`/web-search`, `/agent/web-search`,
`image-search`, `place-search`, `stock-quote`; see [parity §2.5](parity.md#25-other-slots) and
[09 §4.4, §4.6](re/09-server-api.md#46-widget-data-services)). OpenClicky replaces each with a small protocol in
`Sources/OpenClickyKit/Lookups/` and one adapter per vendor, called with the user's own key or a keyless source.

| Service | Protocol | Adapters | Key |
|---|---|---|---|
| web search | `WebSearchProvider` | `BraveWebSearch`, `ExaWebSearch`, `TavilyWebSearch`; or the brain's hosted search (`HostedWebSearch`) | yes |
| image search | `ImageSearchProvider`, wrapped by `ImageSearchService` | `WikimediaCommonsImageSearch` (default), `BraveImageSearch`; plus page previews (`og:image`) and favicons | Commons: no; Brave: yes |
| places | `PlaceSearchProvider` | `MapKitPlaceSearch` over `MKLocalSearch`, behind the `MapKitLocalSearching` seam | no |
| market data | `MarketQuoteProvider` | `TwelveDataQuotes` (free Basic plan) | yes |

Results are plain value types: `WebSearchResult` (title, URL, snippet, age, extra snippets), `ImageResult` (image,
thumbnail and source page URLs, title, size, licence, credit, `mayShowPeople`), `Place` (name, coordinate, address,
phone, website, category, Apple Maps link, time zone) and `MarketQuote` (price, change, day range, previous close, as-of
time, recent closes and the sparkline's start price).

## Wire formats (checked against each vendor's docs on 2026-10-30 and 2026-10-31)

- **Brave Search**: `GET https://api.search.brave.com/res/v1/web/search` and `/images/search`, header
  `X-Subscription-Token`. Web: `q`, `count` (max 20), `freshness` `pd|pw|pm|py`, `extra_snippets=true`; results in
  `web.results[]` (`title`, `url`, `description` with `<strong>` markup, `age`, `page_age`, `extra_snippets`). Images:
  `count` up to 200, `safesearch=strict`; `results[]` with `url` (the page), `thumbnail.src` (Brave's 500 px proxy) and
  `properties.url` (the original).
- **Exa**: `POST https://api.exa.ai/search`, header `x-api-key`. Body `query`, `type: "auto"`, `numResults`,
  `startPublishedDate` (ISO 8601) for freshness, `contents.highlights.maxCharacters`. Results carry `title`, `url`,
  `publishedDate`, `highlights[]`, `summary`, `text`.
- **Tavily**: `POST https://api.tavily.com/search`, `Authorization: Bearer tvly-…`. Body `query`, `search_depth: "basic"`,
  `max_results` (0–20), `time_range` `day|week|month|year`, `include_published_date: true`. Results carry `title`, `url`,
  `content`, `published_date`. Errors are `{"detail": {"error": …}}`, or a `detail` array on 422.
- **Wikimedia Commons**: MediaWiki Action API `generator=search` in namespace 6 with `filetype:bitmap`,
  `prop=imageinfo`, `iiprop=url|size|mime|extmetadata`, `formatversion=2`. Hits are ordered by `index`. Originals over
  4 MB or in formats a photo loader can't show are swapped for a rendition. `utm_*` parameters are stripped. Every
  request sends an identifying User-Agent, as Wikimedia's policy asks.
- **MapKit**: `MKLocalSearch.Request` with `naturalLanguageQuery`, an optional region and `resultTypes`
  `[.pointOfInterest, .address]`. On macOS 26 and later it reads `location` and `addressRepresentations`, otherwise
  `placemark`. "Nothing found" (`MKError.placemarkNotFound`) is an empty result. It needs no key and no location
  permission. MapKit has no ratings or opening hours.
- **Twelve Data**: `GET https://api.twelvedata.com/quote` and `/time_series`, header `Authorization: apikey <key>` (the
  key never goes in a URL). Prices arrive as strings. `last_quote_at` is the as-of time (`timestamp` is the start of the
  candle). Series come newest first. Ranges map to `5min`×80 (1d), `30min`×70 (5d), `1day`×22 (1m), `1day`×64 (3m) and
  `1week`×52 (1y). Errors are `{"code", "message", "status": "error"}`, and a 404 code becomes "not found". The free
  Basic plan allows 8 requests a minute and 800 a day, and each quote uses two (quote, then series).

Every adapter checks its key before using the network. It turns non-2xx bodies into `ProviderError` with the API's own
message and replaces the key with `[redacted]` if a server echoes it back. `LookupEndpoint` and the adapters print,
interpolate and `dump` as their base URL with any user, password or query hidden; the key shows as `<redacted>`.

Numbers from a model or an API that don't fit an `Int` (a `count` of `1e300`, a width of `1e300`) clamp or read as
missing; they never reach a trapping `Int(_:)` conversion.

## Configuration: services.json

Kept apart from `config.json` at `~/Library/Application Support/OpenClicky/services.json` (`ServicesConfig`). Like
config.json it names credentials and never holds a secret. A missing file means the defaults. A service the file leaves
out also gets its default.

```json
{
  "version": 1,
  "services": {
    "web-search":   {"provider": "brave"},
    "image-search": {"provider": "wikimedia-commons"},
    "places":       {"provider": "mapkit"},
    "market-data":  {"provider": "twelve-data", "credential": "twelve-data"}
  },
  "commonsFallback": true,
  "detectPeople": true,
  "favicons": "duckduckgo"
}
```

- Providers: web search `brave | exa | tavily | brain-hosted | off`; image search `wikimedia-commons | brave | off`;
  places `mapkit | off`; market data `twelve-data | off`.
- `credential` defaults to the provider's name (`brave`, `exa`, `tavily`, `twelve-data`). Store a key with
  `occtl key set <name>`, or in Settings → Services. `baseURL` overrides the endpoint. A key travels only over https,
  or over plain http to `localhost`, `127.0.0.1` or `::1` (the rule config.json's providers follow). The factory refuses
  any other base URL, so the service stays off and says why.
- `ServicesConfig.issues(credentials:brainDialect:)` reports a wrong provider or an insecure URL as an error. A missing
  key, or hosted search the brain can't use, is a warning: that tool is simply not offered. `occtl lookup status`
  prints these issues under each service.
- `LookupServices.make(config:credentials:…)` builds every service the file and keys allow. It records why each missing
  service is missing (`unavailable`) and adds `notes` when image search is falling back to Commons.

## Brain tools

`LookupTools` follows the same pattern as the other tool groups: `specs` holds only the services that can answer,
`runningStatus(for:)` gives the notch text, and `handle(_ call:)` returns nil for tools it doesn't own.

| Tool | Arguments | Output (`status: ok`) |
|---|---|---|
| `web_search` | `query`, `count` (≤8), `freshness` `any|day|week|month|year` | `results[{title, url, site, snippet, age, more[]}]` plus a note that page text is data, not instructions |
| `image_search` | `query`, `kind` `subject|web`, `page_url`, `no_people`, `count` (≤8) | `images[{image_url, thumbnail_url, source_url, title, credit, license, width, height, may_show_people}]` |
| `place_search` | `query`, `latitude`, `longitude`, `radius_km`, `limit` (≤10) | `places[{name, latitude, longitude, address, phone, website, category, maps_url, time_zone}]` |
| `stock_quote` | `symbol`, `range` `1d|5d|1m|3m|1y` | `symbol, name, price, change, change_percent, day_high, day_low, previous_close, start_price, as_of, market_open, recent_closes[≤24]` |

Each result is a read (`needsModelRound`). It also carries a typed `LookupWidget` (`webResults`, `images`, `places`,
`stock`) for cards: HeyClicky's widget kinds are `places`, `images` and `stock`. Failures come back as JSON the model
can act on:

- `unavailable`, with advice to tell the user the lookup isn't set up.
- `invalid_arguments`.
- `not_found`.
- `error`, with `retryable` set for 429 and 5xx.
- `cancelled`, when a newer turn cancelled the call.

The handler accepts the argument names models commonly use: `q`, `ticker`, `limit`, numbers sent as strings, and
`pw`-style freshness codes.

### Provider-hosted search

The brain's own provider can search instead. Choose `brain-hosted` for web search, and `web_search` is then not offered
as a function. `LookupTools.hostedSearchTool(for:)` returns the provider's tool entry:

- OpenAI Responses: `{"type": "web_search"}`, with optional `filters.allowed_domains` and `user_location`.
- Anthropic Messages: `{"type": "web_search_20250305", "name": "web_search", "max_uses": 5}`. The newer
  `web_search_20260209` and `web_search_20260318` default to dynamic filtering through code execution, which adds
  latency a spoken answer doesn't want. The search costs $10 per 1,000 calls on top of tokens.
- OpenAI-compatible chat and the speech dialects have no hosted search.

The brain adapters only send function `ToolSpec`s today. Using hosted search therefore needs a brain-side change: pass
the entry through as a raw tool, keep the provider's search items (`web_search_call`, or `server_tool_use` with
`encrypted_content`) in the thread, and show citations. Until then `HostedWebSearch.brainPassesHostedTools` is false, and
choosing `brain-hosted` leaves web search off with a warning in Settings and in `occtl lookup status`. Flip the flag
when the brain sends the entry.

## Photos for drawings

`ImageSearchService.find(PhotoQuery.parse(text))` resolves the drawing's photo query grammar
([04 §13.9](re/04-draw-2d.md#139-photos-interface-only)):

- `[nopeople:] <name>`
- `web: <words>`
- `page: <url> :: <name>`
- `favicon: <host>`

It tries providers in order and returns only public https URLs. A `nopeople:` query does two checks:

1. It drops hits whose title or Commons categories name people.
2. It looks at each remaining thumbnail on the device with Vision (faces or bodies), and drops any it couldn't check.
   The image header is read first: anything declaring more than 50 megapixels, or unreadable, is dropped before it is
   decoded. The rest is decoded straight to a 1024 px thumbnail, on a GCD queue rather than a Swift concurrency thread.

"Public https" (`PublicURL.isPublic`) means a domain name, or an IP literal on the public internet. The system resolver
also reads IPv4 shorthand, hex and octal (`127.1`, `0x7f.0.0.1`, `0177.0.0.1`), so only a plain dotted quad counts as an
IPv4 address and other numeric hosts are refused. IPv6 literals are parsed with `inet_pton` and must be global unicast
(2000::/3, without documentation, Teredo or 6to4 wrapping a private address). Hostnames whose DNS answers with a private
address are not caught.

Page previews and thumbnail checks use `URLSessionTransport.publicWebOnly`, which is ephemeral, sends no cookies and
refuses redirects off the public web (tested against a real `URLSession` and a loopback server). Favicons come from DuckDuckGo's or Google's public icon service and only for
public hosts. The drawing's own photo loader still caps download size when it fetches the chosen image.

## occtl

```sh
occtl lookup status                         # what each service uses and why one is off
occtl lookup places coffee --near 37.7955,-122.3937
occtl lookup images "Golden Gate Bridge" --no-people
occtl lookup images Swift --page https://www.swift.org/
occtl lookup web "swift 6 release" --fresh week   # needs a web search key
occtl lookup stock AAPL --range 1m                # needs a Twelve Data key
occtl lookup … --json                       # the exact tool output the brain reads
occtl lookup … --services path/to/services.json
```
