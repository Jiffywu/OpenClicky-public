import Foundation

/// Plain-text renderings of lookup results, for `occtl lookup` and logs.
public enum LookupFormatting {
    public static func text(_ widget: LookupWidget) -> String {
        switch widget {
        case .webResults(let query, let provider, let results):
            guard !results.isEmpty else { return "No web results for \"\(query)\" (\(provider))." }
            return results.enumerated().map { index, result in
                var lines = ["\(index + 1). \(result.title)", "   \(result.url.absoluteString)"]
                if !result.snippet.isEmpty { lines.append("   \(LookupText.truncate(result.snippet, to: 240))") }
                if let age = result.age { lines.append("   age: \(age)") }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n")

        case .images(let query, let images):
            guard !images.isEmpty else { return "No images for \"\(query)\"." }
            return images.enumerated().map { index, image in
                var lines = ["\(index + 1). \(image.title ?? image.imageURL.lastPathComponent)  [\(image.provider)]",
                             "   image: \(image.imageURL.absoluteString)"]
                if let page = image.sourcePageURL { lines.append("   page:  \(page.absoluteString)") }
                var facts: [String] = []
                if let width = image.width, let height = image.height { facts.append("\(width)x\(height)") }
                if let license = image.license { facts.append(license) }
                if let credit = image.credit { facts.append("by \(LookupText.truncate(credit, to: 60))") }
                if let people = image.mayShowPeople { facts.append(people ? "may show people" : "no people seen") }
                if !facts.isEmpty { lines.append("   " + facts.joined(separator: " · ")) }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n")

        case .places(let query, let places):
            guard !places.isEmpty else { return "No places found for \"\(query)\"." }
            return places.enumerated().map { index, place in
                var lines = ["\(index + 1). \(place.name)\(place.category.map { "  (\($0))" } ?? "")",
                             String(format: "   %.5f, %.5f", place.coordinate.latitude, place.coordinate.longitude)]
                if let address = place.address { lines.append("   \(address)") }
                if let phone = place.phone { lines.append("   phone: \(phone)") }
                if let website = place.website { lines.append("   web: \(website.absoluteString)") }
                if let maps = place.mapsURL { lines.append("   maps: \(maps.absoluteString)") }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n")

        case .stock(let quote):
            var lines = ["\(quote.symbol)\(quote.name.map { "  \($0)" } ?? "")\(quote.exchange.map { "  (\($0))" } ?? "")"]
            let currency = quote.currency.map { " \($0)" } ?? ""
            var priceLine = "  price: \(number(quote.price))\(currency)"
            if let change = quote.change {
                priceLine += "  change: \(change >= 0 ? "+" : "")\(number(change))"
                if let percent = quote.changePercent { priceLine += " (\(percent >= 0 ? "+" : "")\(number(percent, places: 2))%)" }
            }
            lines.append(priceLine)
            if let low = quote.dayLow, let high = quote.dayHigh { lines.append("  day range: \(number(low)) – \(number(high))") }
            if let previous = quote.previousClose { lines.append("  previous close: \(number(previous))") }
            if let asOf = quote.asOf { lines.append("  as of: \(LookupDates.iso(asOf))\(quote.isMarketOpen.map { $0 ? " (market open)" : " (market closed)" } ?? "")") }
            if !quote.recentCloses.isEmpty {
                lines.append("  \(quote.range.rawValue) closes (\(quote.recentCloses.count)): \(sparkline(quote.recentCloses))")
            }
            return lines.joined(separator: "\n")
        }
    }

    static func number(_ value: Double, places: Int = 2) -> String {
        let magnitude = abs(value)
        let digits = magnitude != 0 && magnitude < 1 ? max(places, 4) : places
        return String(format: "%.\(digits)f", value)
    }

    /// A one-line text sparkline of `values`.
    public static func sparkline(_ values: [Double]) -> String {
        let ticks = Array("▁▂▃▄▅▆▇█")
        guard let low = values.min(), let high = values.max() else { return "" }
        let span = high - low
        return String(LookupTools.downsample(values, to: 48).map { value in
            guard span > 0, span.isFinite else { return ticks[3] }
            return ticks[min(Int((value - low) / span * Double(ticks.count - 1)), ticks.count - 1)]
        })
    }
}
