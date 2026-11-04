// Market quotes from Twelve Data (free Basic plan: 8 requests a minute, 800 a day; US equities and ETFs, forex,
// crypto; checked on https://twelvedata.com/pricing on 2026-10-30).
//
// Checked against https://twelvedata.com/docs on 2026-10-30:
// - Auth: header `Authorization: apikey <key>` (the documented, recommended form; keeps the key out of URLs) or an
//   `apikey` query parameter.
// - `GET {base}/quote?symbol=AAPL` → `symbol`, `name`, `exchange`, `mic_code`, `currency`, `datetime`, `timestamp`
//   (integer, the start of the interval's candle), `last_quote_at` (integer, when the price last changed), `open`,
//   `high`, `low`, `close`, `volume`, `previous_close`, `change`, `percent_change`, `is_market_open`,
//   `fifty_two_week{…}`. Prices are JSON strings ("148.85001").
// - `GET {base}/time_series?symbol=AAPL&interval=1day&outputsize=22` → `meta{symbol, interval, currency, …}`,
//   `values[]{datetime, open, high, low, close, volume}` (strings; `order` defaults to desc, newest first), `status: "ok"`. Intervals include
//   5min, 30min, 1day, 1week.
// - Errors: `{"code": 400, "message": "…", "status": "error"}`. The docs map codes to HTTP statuses, but the body is
//   checked on 2xx too.
// A quote costs two requests (quote, then series), made one after the other.

import Foundation

public struct TwelveDataQuotes: MarketQuoteProvider {
    public static let defaultBaseURL = URL(string: "https://api.twelvedata.com")!
    public let providerID = "twelve-data"
    let endpoint: LookupEndpoint

    public init(endpoint: LookupEndpoint) { self.endpoint = endpoint }

    public func quote(symbol: String, range: QuoteRange) async throws -> MarketQuote {
        let ticker = try MarketSymbol.normalize(symbol)
        let key = try endpoint.requireKey(provider: "Twelve Data", service: "Market data")
        let headers = ["Authorization": "apikey \(key)"]

        let quoteJSON = try await fetch(endpoint.get(endpoint.url("quote", query: [URLQueryItem(name: "symbol", value: ticker)]),
                                                     headers: headers), ticker: ticker)
        var quote = try Self.quote(from: quoteJSON, ticker: ticker, range: range)

        let (interval, size) = Self.series(for: range)
        let seriesURL = endpoint.url("time_series", query: [URLQueryItem(name: "symbol", value: ticker),
                                                            URLQueryItem(name: "interval", value: interval),
                                                            URLQueryItem(name: "outputsize", value: String(size))])
        // The quote is the answer; a failed sparkline only leaves the line empty.
        if let seriesJSON = try? await fetch(endpoint.get(seriesURL, headers: headers), ticker: ticker) {
            quote.recentCloses = Self.closes(from: seriesJSON, range: range)
        }
        try Task.checkCancellation()
        quote.startPrice = range == .day ? (quote.previousClose ?? quote.recentCloses.first) : (quote.recentCloses.first ?? quote.previousClose)
        return quote
    }

    private func fetch(_ request: URLRequest, ticker: String) async throws -> JSONValue {
        let json = try await endpoint.fetchJSON(request, provider: providerID)
        if json["status"]?.stringValue == "error" {
            let code = json["code"]?.looseInt
            let message = endpoint.redact(json["message"]?.stringValue ?? "the request failed")
            if code == 404 { throw LookupError.notFound("No market data for \(ticker): \(message)") }
            throw ProviderError(provider: providerID, status: code, message: message)
        }
        return json
    }

    /// Interval and number of points for each sparkline span.
    static func series(for range: QuoteRange) -> (interval: String, size: Int) {
        switch range {
        case .day: ("5min", 80)      // a 6.5 h session is 78 bars
        case .week: ("30min", 70)    // 13 bars a day for 5 days
        case .month: ("1day", 22)
        case .quarter: ("1day", 64)
        case .year: ("1week", 52)
        }
    }

    static func quote(from json: JSONValue, ticker: String, range: QuoteRange) throws -> MarketQuote {
        guard let price = json["close"]?.looseDouble else {
            throw LookupError.notFound("No price came back for \(ticker).")
        }
        return MarketQuote(
            symbol: LookupText.nonEmpty(json["symbol"]?.stringValue) ?? ticker,
            name: LookupText.nonEmpty(json["name"]?.stringValue),
            exchange: LookupText.nonEmpty(json["exchange"]?.stringValue),
            currency: LookupText.nonEmpty(json["currency"]?.stringValue),
            price: price,
            change: json["change"]?.looseDouble,
            changePercent: json["percent_change"]?.looseDouble,
            open: json["open"]?.looseDouble,
            dayHigh: json["high"]?.looseDouble,
            dayLow: json["low"]?.looseDouble,
            previousClose: json["previous_close"]?.looseDouble,
            // `last_quote_at` is when the price was last updated; `timestamp` is the start of the day's candle.
            asOf: (json["last_quote_at"]?.looseDouble ?? json["timestamp"]?.looseDouble).map { Date(timeIntervalSince1970: $0) }
                ?? LookupDates.parse(json["datetime"]?.stringValue),
            isMarketOpen: json["is_market_open"]?.looseBool,
            range: range)
    }

    /// Closes oldest first. A one-day range keeps only the latest session's bars.
    static func closes(from json: JSONValue, range: QuoteRange) -> [Double] {
        var points: [(String, Double)] = (json["values"]?.arrayValue ?? []).compactMap { value in
            guard let time = value["datetime"]?.stringValue, let close = value["close"]?.looseDouble else { return nil }
            return (time, close)
        }
        // "2026-10-30 15:55:00" and "2026-10-30" sort correctly as text.
        points.sort { $0.0 < $1.0 }
        if range == .day, let lastDay = points.last.map({ String($0.0.prefix(10)) }) {
            points = points.filter { $0.0.hasPrefix(lastDay) }
        }
        return points.map(\.1)
    }
}

/// Ticker checks shared by quote providers.
enum MarketSymbol {
    /// "$aapl " → "AAPL". Letters, digits and `. - / : ^ = _` only (BRK.B, BTC/USD, ^GSPC).
    static func normalize(_ symbol: String) throws -> String {
        var text = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("$") { text.removeFirst() }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-/:^=_"))
        guard !text.isEmpty, text.count <= 24, text.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }) else {
            throw LookupError.invalidQuery("\"\(symbol)\" is not a ticker symbol.")
        }
        return text
    }
}

extension TwelveDataQuotes: CustomStringConvertible, CustomReflectable {
    public var description: String { "TwelveDataQuotes(base: \(endpoint.redactedBase))" }
    public var customMirror: Mirror { Mirror(self, children: ["base": endpoint.redactedBase], displayStyle: .struct) }
}
