import Foundation

// When a voice, listening or always-on session can't open, OpenClicky asks the provider's models list directly (a
// free GET) to find out why, and says so in plain words: the provider doesn't serve this country or region, this
// network blocks it, the Mac is offline, the key was turned down, or the provider is down. HeyClicky does the same for
// its realtime voice (docs/re/02-voice-pipeline.md §15); OpenClicky does it for every network provider.

/// What the probe found out.
public enum ProviderVerdict: String, Sendable, Hashable, Codable, CaseIterable {
    /// The provider answered normally: it is reachable, so the failure is about this model, voice or request.
    case reachable
    /// The provider turned the API key down (401, or a 403 that names the key).
    case keyRejected = "key-rejected"
    /// The provider doesn't serve the country or region this Mac is in.
    case regionUnsupported = "region-unsupported"
    /// Something between this Mac and the provider (a firewall, proxy, VPN or DNS filter) stops the connection.
    case networkBlocked = "network-blocked"
    /// This Mac has no internet connection.
    case offline
    /// The provider didn't answer in time: a network that silently drops the traffic, or a slow provider.
    case noAnswer = "no-answer"
    /// The provider is limiting requests.
    case rateLimited = "rate-limited"
    /// The provider answered with a server error.
    case providerDown = "provider-down"
    /// The provider refused for another reason (account or permission).
    case forbidden
    /// Runs on this Mac; there is nothing to probe.
    case onDevice = "on-device"
    /// The probe was inconclusive.
    case unknown
}

/// The raw result of one probe request.
public struct ProviderProbeResult: Sendable, Hashable {
    public enum Outcome: Sendable, Hashable {
        /// The server answered (status and the start of its body).
        case answered(status: Int, body: String, contentType: String?)
        /// The request failed before any answer.
        case failed(URLError.Code)
    }

    public var url: URL
    public var outcome: Outcome
    public var seconds: Double

    public init(url: URL, outcome: Outcome, seconds: Double) {
        self.url = url
        self.outcome = outcome
        self.seconds = seconds
    }

    public var summary: String {
        switch outcome {
        case .answered(let status, _, _): "\(url.host ?? "?") answered HTTP \(status) in \(String(format: "%.2f", seconds)) s"
        case .failed(let code): "\(url.host ?? "?") failed with URL error \(code.rawValue) after \(String(format: "%.2f", seconds)) s"
        }
    }
}

/// A plain account of why a provider session could not open.
public struct ProviderDiagnosis: Sendable, Hashable, CustomStringConvertible {
    /// What the user was trying to use, as words for the explanation.
    public enum Purpose: String, Sendable, Hashable, Codable {
        case listening, voice, alwaysOnVoice = "always-on voice", brain, quickTextWork = "quick text work", agent

        public init(slot: SlotID) {
            switch slot {
            case .stt: self = .listening
            case .voice: self = .voice
            case .realtimeVoice: self = .alwaysOnVoice
            case .brain: self = .brain
            case .brainFast: self = .quickTextWork
            case .agent: self = .agent
            }
        }

        var noun: String {
            switch self {
            case .listening: "Listening"
            case .voice: "The voice"
            case .alwaysOnVoice: "Always-on voice"
            case .brain: "The brain"
            case .quickTextWork: "Quick text work"
            case .agent: "The background agent"
            }
        }
    }

    public var providerID: String
    /// "OpenAI", "Google Gemini", or the provider's id when OpenClicky doesn't know the host.
    public var providerName: String
    public var host: String
    public var purpose: Purpose
    public var verdict: ProviderVerdict
    /// What the probe saw, for logs and the diagnostics bundle (never a key).
    public var probe: String?
    /// The original failure, for logs.
    public var failure: String

    public init(providerID: String, providerName: String, host: String, purpose: Purpose, verdict: ProviderVerdict,
                probe: String?, failure: String) {
        self.providerID = providerID
        self.providerName = providerName
        self.host = host
        self.purpose = purpose
        self.verdict = verdict
        self.probe = probe
        self.failure = failure
    }

    /// One or two plain sentences for the notch, Settings and the spoken notice.
    public var explanation: String {
        let what = purpose.noun
        switch verdict {
        case .regionUnsupported:
            return "\(providerName) doesn't offer its service in your country or region, so \(what.lowercasedFirst) can't connect. "
                + "Choose another provider for it in Settings → Models."
        case .networkBlocked:
            return "This network is blocking \(host), so \(what.lowercasedFirst) can't reach \(providerName). "
                + "A firewall, proxy, VPN or content filter may be in the way; try another network."
        case .offline:
            return "This Mac isn't connected to the internet, so \(what.lowercasedFirst) can't reach \(providerName)."
        case .noAnswer:
            return "\(providerName) didn't answer in time, so \(what.lowercasedFirst) couldn't connect. "
                + "This network may be blocking \(host), or \(providerName) is slow right now; try again in a minute."
        case .keyRejected:
            return "\(providerName) turned down the API key, so \(what.lowercasedFirst) can't connect. Check the key in Settings → Providers & keys."
        case .rateLimited:
            return "\(providerName) is limiting requests right now, so \(what.lowercasedFirst) couldn't connect. Wait a minute and try again."
        case .providerDown:
            return "\(providerName) is having trouble right now, so \(what.lowercasedFirst) couldn't connect. Try again in a minute."
        case .forbidden:
            return "\(providerName) refused the connection for this account, so \(what.lowercasedFirst) can't start. Check the account and key in Settings."
        case .reachable:
            return "\(providerName) is reachable, but it turned this request down: \(Self.shortened(failure))"
        case .onDevice, .unknown:
            return "\(what) couldn't connect to \(providerName): \(Self.shortened(failure))"
        }
    }

    /// A short title for a notice.
    public var headline: String {
        switch verdict {
        case .regionUnsupported: "\(providerName) isn't available in your region."
        case .networkBlocked: "This network is blocking \(providerName)."
        case .offline: "No internet connection."
        case .noAnswer: "\(providerName) didn't answer."
        case .keyRejected: "\(providerName) turned down the API key."
        case .rateLimited: "\(providerName) is busy."
        case .providerDown: "\(providerName) is having trouble."
        case .forbidden: "\(providerName) refused the connection."
        case .reachable, .onDevice, .unknown: "\(purpose.noun) couldn't connect."
        }
    }

    public var description: String { explanation }

    static func shortened(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > 220 ? String(flat.prefix(217)) + "…" : flat
    }
}

/// The error a session open throws once it has been diagnosed. Its description is the plain explanation, so every
/// place that already shows an error's text (the notch, always-on's notice, logs) says what went wrong.
public struct ProviderUnavailableError: Error, Sendable, CustomStringConvertible, CustomDebugStringConvertible, LocalizedError, SpokenError {
    public var diagnosis: ProviderDiagnosis
    /// The underlying error, described (it may not be Sendable itself).
    public var underlying: String
    /// The provider's own refusal when that was the underlying error, so its status still reads after diagnosis.
    public var providerError: ProviderError?

    public init(diagnosis: ProviderDiagnosis, underlying: String, providerError: ProviderError? = nil) {
        self.diagnosis = diagnosis
        self.underlying = underlying
        self.providerError = providerError
    }

    public var description: String { diagnosis.explanation }
    public var debugDescription: String { "\(diagnosis.explanation) [\(diagnosis.verdict.rawValue); \(diagnosis.probe ?? "no probe"); \(underlying)]" }
    public var errorDescription: String? { diagnosis.explanation }
    public var spokenExplanation: String { diagnosis.explanation }
}

/// An error that carries its own sentence for the voice to say (instead of a generic "something went wrong").
public protocol SpokenError: Error {
    var spokenExplanation: String { get }
}

/// Probes one provider with a cheap models-list request.
public struct ProviderProbe: Sendable {
    public var http: any HTTPTransport
    /// The probe gives up after this long (it runs while a person waits).
    public var timeout: TimeInterval

    public init(http: any HTTPTransport = URLSessionTransport(), timeout: TimeInterval = 6) {
        self.http = http
        self.timeout = timeout
    }

    /// The models-list URL on the provider's own host, or nil for on-device and harness providers.
    public static func probeURL(for provider: ProviderConfig) -> URL? {
        let fallback: String
        switch provider.dialect {
        case .appleSpeech, .appleSpeechSynthesis, .harnessLogin: return nil
        case .openAIResponses, .openAIChat, .openAISpeech, .openAITranscription, .openAIRealtime: fallback = "https://api.openai.com/v1"
        case .anthropicMessages: fallback = "https://api.anthropic.com"
        case .elevenLabsSpeech: fallback = "https://api.elevenlabs.io"
        case .deepgramListen: fallback = "https://api.deepgram.com/v1/listen"
        case .geminiLive, .geminiSpeech: fallback = "https://generativelanguage.googleapis.com/v1beta"
        }
        guard var components = URLComponents(url: provider.baseURL ?? URL(string: fallback)!, resolvingAgainstBaseURL: false),
              components.host != nil else { return nil }
        switch components.scheme?.lowercased() {
        case "wss": components.scheme = "https"
        case "ws": components.scheme = "http"
        default: break
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        switch provider.dialect {
        case .openAIRealtime:
            if path.hasSuffix("/realtime") { path.removeLast("/realtime".count) }
            path += path.isEmpty ? "/v1/models" : "/models"
        case .openAIResponses, .openAIChat, .openAISpeech, .openAITranscription:
            path += path.isEmpty ? "/v1/models" : "/models"
        case .anthropicMessages, .elevenLabsSpeech:
            path = path.hasSuffix("/v1") ? path + "/models" : (path.isEmpty ? "/v1/models" : path + "/v1/models")
        case .deepgramListen:
            path = "/v1/models"
        case .geminiLive, .geminiSpeech:
            // The Live socket's base lives under /ws/…; the models list is on the REST version the base names.
            let version = ["/v1beta", "/v1alpha", "/v1"].first { path.contains($0) } ?? "/v1beta"
            path = version + "/models"
            components.queryItems = [URLQueryItem(name: "pageSize", value: "1")]
        default:
            return nil
        }
        components.path = path
        return components.url
    }

    /// The request for a probe: a GET on the provider's own host with its usual auth header when a key is given.
    public static func request(for provider: ProviderConfig, url: URL, apiKey: String?, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = apiKey, !key.isEmpty {
            switch provider.dialect {
            case .anthropicMessages:
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            case .elevenLabsSpeech: request.setValue(key, forHTTPHeaderField: "xi-api-key")
            case .deepgramListen: request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
            case .geminiLive, .geminiSpeech: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            default: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    /// Asks the provider's models list. Nil for providers with nothing to probe.
    public func probe(_ provider: ProviderConfig, apiKey: String?) async -> ProviderProbeResult? {
        guard let url = Self.probeURL(for: provider) else { return nil }
        let request = Self.request(for: provider, url: url, apiKey: apiKey, timeout: timeout)
        let started = Date()
        let timeout = self.timeout
        let http = self.http
        let outcome: ProviderProbeResult.Outcome = await withTaskGroup(of: ProviderProbeResult.Outcome?.self) { group in
            group.addTask {
                do {
                    let (data, response) = try await http.data(for: request)
                    return .answered(status: response.statusCode, body: String(decoding: data.prefix(4_096), as: UTF8.self),
                                     contentType: response.value(forHTTPHeaderField: "Content-Type"))
                } catch let error as URLError {
                    return .failed(error.code)
                } catch {
                    return Task.isCancelled ? nil : .failed(.unknown)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout + 0.5))
                return Task.isCancelled ? nil : .failed(.timedOut)
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failed(.cancelled)
        }
        return ProviderProbeResult(url: url, outcome: outcome, seconds: Date().timeIntervalSince(started))
    }

    /// What a probe's result means.
    public static func classify(_ result: ProviderProbeResult) -> ProviderVerdict {
        switch result.outcome {
        case .failed(let code):
            return classify(networkCode: code)
        case .answered(let status, let body, let contentType):
            if mentionsRegion(body) || status == 451 { return .regionUnsupported }
            switch status {
            case 200..<300: return .reachable
            case 401: return .keyRejected
            case 407: return .networkBlocked
            case 403:
                // A firewall's own block page is HTML; the provider's APIs answer JSON.
                if let type = contentType?.lowercased(), type.contains("text/html") { return .networkBlocked }
                if mentionsKey(body) { return .keyRejected }
                return .forbidden
            case 429: return .rateLimited
            case 500...599: return .providerDown
            case 300..<400: return .networkBlocked // a captive portal or proxy redirect
            case 404, 400, 405: return .reachable // the host answered as an API; the probe path is just not served
            default: return .unknown
            }
        }
    }

    /// The verdict for a network failure.
    public static func classify(networkCode code: URLError.Code) -> ProviderVerdict {
        switch code {
        case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed, .callIsActive: .offline
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired, .networkConnectionLost, .appTransportSecurityRequiresSecureConnection:
            .networkBlocked
        case .timedOut: .noAnswer
        default: .unknown
        }
    }

    /// The phrases providers use for a region they don't serve.
    static func mentionsRegion(_ body: String) -> Bool {
        let text = body.lowercased()
        return ["unsupported_country_region_territory", "unsupported_country", "country, region, or territory not supported",
                "user location is not supported", "not available in your country", "not available in your region",
                "region is not supported", "unsupported region", "location is not supported"].contains { text.contains($0) }
    }

    static func mentionsKey(_ body: String) -> Bool {
        let text = body.lowercased()
        return ["api key", "api_key", "invalid_api_key", "authentication", "unauthorized", "x-api-key"].contains { text.contains($0) }
    }

    /// A friendly name for a provider's host.
    public static func displayName(host: String, providerID: String) -> String {
        let host = host.lowercased()
        if host.hasSuffix("openai.com") { return "OpenAI" }
        if host.hasSuffix("anthropic.com") { return "Anthropic" }
        if host.hasSuffix("elevenlabs.io") { return "ElevenLabs" }
        if host.hasSuffix("deepgram.com") { return "Deepgram" }
        if host.hasSuffix("googleapis.com") { return "Google Gemini" }
        if host.hasSuffix("openrouter.ai") { return "OpenRouter" }
        if host.hasSuffix("deepseek.com") { return "DeepSeek" }
        if host == "127.0.0.1" || host == "localhost" { return "the local model server" }
        return providerID
    }
}

/// Probes a provider after a session failed to open, and words what it found. Results are kept for a short while per
/// provider, so a run of failures doesn't send a probe each time.
public final class ProviderDiagnostician: @unchecked Sendable {
    private let probe: ProviderProbe
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cache: [String: (at: Date, verdict: ProviderVerdict, probe: String?)] = [:]

    public init(probe: ProviderProbe = ProviderProbe(), ttl: TimeInterval = 120, now: @escaping @Sendable () -> Date = { Date() }) {
        self.probe = probe
        self.ttl = ttl
        self.now = now
    }

    /// Whether a failure is the kind a probe can explain (a refused or failed connection), not a cancellation or a
    /// local problem.
    public static func shouldDiagnose(_ error: Error) -> Bool {
        if error is CancellationError || error is ProviderUnavailableError { return false }
        if let urlError = error as? URLError { return urlError.code != .cancelled }
        return error is ProviderError
    }

    /// A diagnosis of `failure` for `provider` (used for `purpose`). On-device providers get `.onDevice` without a probe.
    public func diagnose(provider: ProviderConfig, apiKey: String?, purpose: ProviderDiagnosis.Purpose, failure: Error) async -> ProviderDiagnosis {
        let url = ProviderProbe.probeURL(for: provider)
        let host = url?.host ?? provider.baseURL?.host ?? provider.id
        let name = ProviderProbe.displayName(host: host, providerID: provider.id)
        let failureText = (failure as? LocalizedError)?.errorDescription ?? String(describing: failure)
        func make(_ verdict: ProviderVerdict, _ probeText: String?) -> ProviderDiagnosis {
            ProviderDiagnosis(providerID: provider.id, providerName: name, host: host, purpose: purpose, verdict: verdict,
                              probe: probeText, failure: failureText)
        }
        guard url != nil else { return make(.onDevice, nil) }
        // A failure that already says what happened needs no probe.
        if let direct = Self.directVerdict(failure) { return make(direct, "from the failure itself") }
        let key = provider.id + "|" + (url?.absoluteString ?? "")
        if let cached = lock.withLock({ cache[key] }), now().timeIntervalSince(cached.at) < ttl {
            return make(cached.verdict, (cached.probe ?? "") + " (cached)")
        }
        guard let result = await probe.probe(provider, apiKey: apiKey) else { return make(.unknown, nil) }
        var verdict = ProviderProbe.classify(result)
        // The host answers, but the session still failed on a network error: something on the path blocks the
        // streaming connection only (a proxy that refuses WebSocket upgrades, for one).
        if verdict == .reachable, let code = Self.networkCode(in: failure), ProviderProbe.classify(networkCode: code) == .networkBlocked {
            verdict = .networkBlocked
        }
        // A probe the caller cancelled (the user let go of the keys or pressed Escape), or one that learned nothing,
        // says nothing about the provider: caching it would hide the real reason for the next two minutes.
        if !Task.isCancelled, verdict != .unknown, result.outcome != .failed(.cancelled) {
            lock.withLock { cache[key] = (now(), verdict, result.summary) }
        }
        return make(verdict, result.summary)
    }

    /// The URL error behind a failure: the error itself, or one an adapter folded into its message
    /// ("… (NSURLErrorDomain error -1009.)").
    static func networkCode(in failure: Error) -> URLError.Code? {
        if let urlError = failure as? URLError { return urlError.code }
        let text = (failure as? ProviderError)?.message ?? String(describing: failure)
        guard let range = text.range(of: #"NSURLErrorDomain(?: error |:|, code=| Code=)(-?[0-9]+)"#, options: .regularExpression),
              let number = text[range].range(of: #"-?[0-9]+"#, options: .regularExpression),
              let raw = Int(text[range][number]) else { return nil }
        return URLError.Code(rawValue: raw)
    }

    /// The verdict a failure states outright: a region refusal, a turned-down key, or no network at all.
    static func directVerdict(_ failure: Error) -> ProviderVerdict? {
        if let code = networkCode(in: failure), ProviderProbe.classify(networkCode: code) == .offline { return .offline }
        guard let provider = failure as? ProviderError else { return nil }
        if ProviderProbe.mentionsRegion(provider.message) || provider.status == 451 { return .regionUnsupported }
        if provider.status == 401 { return .keyRejected }
        return nil
    }
}

private extension String {
    var lowercasedFirst: String {
        guard let first else { return self }
        // Keep "OpenAI"-style names as they are; lower only the purpose nouns ("The voice" → "the voice").
        return first.lowercased() + dropFirst()
    }
}
