import Foundation
import ImageIO
import Vision

/// Looks at an image and says whether it shows people. The drawing's "no people" photo option relies on it
/// (04 §13.9: a `nopeople:` query skips hits that show people).
public protocol PeopleDetecting: Sendable {
    func containsPeople(_ imageData: Data) async throws -> Bool
}

/// On-device check with Vision: any face, or any human body, at reasonable confidence. Needs no permission.
///
/// The bytes come from third-party URLs, so the image header is read first: anything over `maxPixels` (a small file can
/// declare a gigapixel canvas) or unreadable is refused before decoding. The rest is decoded straight to a thumbnail no
/// longer than `maxSide`, which is all face and body detection needs. Decoding and detection block, so they run on a
/// GCD queue, not on Swift's cooperative threads.
public struct VisionPeopleDetector: PeopleDetecting {
    public enum ImageError: Error, Sendable, Equatable {
        case unreadable
        case tooLarge(width: Int, height: Int)
    }

    public var minimumConfidence: Float
    public var maxPixels: Int
    public var maxSide: Int

    public init(minimumConfidence: Float = 0.5, maxPixels: Int = 50_000_000, maxSide: Int = 1_024) {
        self.minimumConfidence = minimumConfidence
        self.maxPixels = maxPixels
        self.maxSide = maxSide
    }

    public func containsPeople(_ imageData: Data) async throws -> Bool {
        let (threshold, maxPixels, maxSide) = (minimumConfidence, maxPixels, maxSide)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    let image = try Self.preparedImage(from: imageData, maxPixels: maxPixels, maxSide: maxSide)
                    return try Self.detect(in: image, threshold: threshold)
                })
            }
        }
    }

    /// The image decoded as a thumbnail at most `maxSide` pixels long, after its header passed the pixel limit.
    static func preparedImage(from data: Data, maxPixels: Int, maxSide: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, width > 0, height > 0 else {
            throw ImageError.unreadable
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maxPixels else { throw ImageError.tooLarge(width: width, height: height) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxSide, 64),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ImageError.unreadable }
        return image
    }

    static func detect(in image: CGImage, threshold: Float) throws -> Bool {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        let bodies = VNDetectHumanRectanglesRequest()
        bodies.upperBodyOnly = false
        try handler.perform([faces, bodies])
        let sawFace = (faces.results ?? []).contains { $0.confidence >= threshold }
        let sawBody = (bodies.results ?? []).contains { $0.confidence >= threshold }
        return sawFace || sawBody
    }
}

/// Cheap first pass on words that come with a result (title, description, Commons categories). Catches portraits
/// and crowd shots without downloading anything. Deliberately avoids words with common non-human senses ("face" of a
/// mountain, "player", "family" in taxonomy), so it misses some people photos; the detector catches the rest.
enum PeopleHeuristic {
    static let words: Set<String> = [
        "person", "persons", "people", "portrait", "portraits", "headshot", "headshots", "selfie", "selfies",
        "man", "men", "woman", "women", "boy", "boys", "girl", "girls", "child", "children", "kid", "kids",
        "baby", "babies", "toddler", "toddlers", "teenager", "teenagers", "crowd", "crowds", "audience", "spectators",
        "actor", "actors", "actress", "actresses", "singer", "singers", "musician", "musicians", "athlete", "athletes",
        "politician", "politicians", "bride", "groom", "wedding", "human", "humans", "tourists", "pedestrians",
        "soldier", "soldiers", "dancer", "dancers", "students", "pupils", "couple", "gentleman", "lady", "ladies",
    ]

    static func suggestsPeople(_ result: ImageResult) -> Bool {
        let text = ([result.title ?? ""] + result.keywords).joined(separator: " ").lowercased()
        let tokens = text.split { !$0.isLetter }
        return tokens.contains { words.contains(String($0)) }
    }
}

/// Removes results that show people: the word heuristic first, then (when a detector is set) a look at each
/// remaining thumbnail. A thumbnail that cannot be fetched or decoded counts as "can't promise", so it is dropped.
public struct PeopleFilter: Sendable {
    public var detector: (any PeopleDetecting)?
    let http: any HTTPTransport
    let userAgent: String
    /// Thumbnails larger than this are not downloaded in full and are dropped.
    let maxImageBytes: Int
    /// At most this many thumbnails are checked per search.
    let maxChecks: Int

    public init(detector: (any PeopleDetecting)? = VisionPeopleDetector(), http: any HTTPTransport = URLSessionTransport.publicWebOnly,
                userAgent: String = LookupEndpoint.defaultUserAgent, maxImageBytes: Int = 2_000_000, maxChecks: Int = 12) {
        self.detector = detector
        self.http = http
        self.userAgent = userAgent
        self.maxImageBytes = maxImageBytes
        self.maxChecks = maxChecks
    }

    /// Marks results the word heuristic flags. Never removes anything.
    public static func annotate(_ results: [ImageResult]) -> [ImageResult] {
        results.map { result in
            var result = result
            if result.mayShowPeople == nil, PeopleHeuristic.suggestsPeople(result) { result.mayShowPeople = true }
            return result
        }
    }

    /// Up to `limit` results that do not appear to show people, in their original order.
    public func withoutPeople(_ results: [ImageResult], limit: Int) async -> [ImageResult] {
        let candidates = Self.annotate(results).filter { $0.mayShowPeople != true }
        guard let detector else { return Array(candidates.prefix(limit)) }
        let checked = Array(candidates.prefix(maxChecks))
        let verdicts = await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, result) in checked.enumerated() {
                group.addTask { (index, await self.isClear(result, detector: detector)) }
            }
            var clear = [Bool](repeating: false, count: checked.count)
            for await (index, isClear) in group { clear[index] = isClear }
            return clear
        }
        var kept: [ImageResult] = []
        for (index, var result) in checked.enumerated() where verdicts[index] {
            result.mayShowPeople = false
            kept.append(result)
            if kept.count == limit { break }
        }
        return kept
    }

    private func isClear(_ result: ImageResult, detector: any PeopleDetecting) async -> Bool {
        let url = result.thumbnailURL ?? result.imageURL
        guard PublicURL.isPublic(url), let data = try? await download(url) else { return false }
        guard let hasPeople = try? await detector.containsPeople(data) else { return false }
        return !hasPeople
    }

    func download(_ url: URL) async throws -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (stream, response) = try await http.stream(for: request)
        guard (200..<300).contains(response.statusCode) else { return nil }
        var data = Data()
        for try await chunk in stream {
            data.append(chunk)
            if data.count > maxImageBytes { return nil }
        }
        return data
    }
}
