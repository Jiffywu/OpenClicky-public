import CoreGraphics
import Foundation

/// Media answers for a rehearsal (`occtl draw --media …`, tests, evidence renders). Rehearsals run on a virtual clock
/// and can't wait for the network, so the program's requests are found first (`DrawingMediaPrefetch`), answered (live
/// or by fakes), and then patched in during the rehearsal `delay` seconds after each request, the way a live
/// lookup arrives while the voice talks.
public struct DrawingRehearsalMedia: Sendable {
    public var store: DrawingMediaStore
    /// Mark fields by request cache key (`DrawingMediaRequest.cacheKey`).
    public var answers: [String: JSONValue]
    /// Seconds after its request that an answer arrives (0 = before the first line is spoken).
    public var delay: TimeInterval

    public init(store: DrawingMediaStore = DrawingMediaStore(), answers: [String: JSONValue] = [:], delay: TimeInterval = 0) {
        self.store = store
        self.answers = answers
        self.delay = delay
    }

    /// Answer every request with `lookups`, store the images, and keep the fields by key.
    public static func resolve(_ requests: [DrawingMediaRequest], with lookups: any DrawingMediaLookups,
                               store: DrawingMediaStore = DrawingMediaStore(), delay: TimeInterval = 0) async -> (media: DrawingRehearsalMedia, results: [(DrawingMediaRequest, DrawingMediaResolution)]) {
        var unique: [String: DrawingMediaRequest] = [:]
        for request in requests where unique[request.cacheKey] == nil { unique[request.cacheKey] = request }
        let resolved = await withTaskGroup(of: (DrawingMediaRequest, DrawingMediaResolution).self) { group in
            for request in unique.values { group.addTask { (request, await request.resolve(with: lookups)) } }
            var all: [(DrawingMediaRequest, DrawingMediaResolution)] = []
            for await item in group { all.append(item) }
            return all
        }
        var media = DrawingRehearsalMedia(store: store, delay: delay)
        for (request, resolution) in resolved {
            for (key, image) in resolution.images { store.put(image, for: key) }
            media.answers[request.cacheKey] = resolution.fields
        }
        let ordered = requests.compactMap { request in resolved.first { $0.0.cacheKey == request.cacheKey } }
        return (media, ordered)
    }
}

/// Finds the media requests a program makes without drawing it (pace "now", no painter).
public enum DrawingMediaPrefetch {
    public static func requests(in program: String, width: Double = 1280, height: Double = 832) throws -> [DrawingMediaRequest] {
        let host = try DrawingEngineHost()
        var events = host.perform(.begin(DrawingBeginOptions(width: width, height: height, pace: .now)))
        events += host.perform(.append(program))
        events += host.perform(.end)
        events += host.perform(.cancel)
        return events.compactMap(DrawingMediaRequest.init(event:))
    }
}
