import Foundation

// Shared retries for provider calls (docs/infra.md). A brain, voice or listening call that fails with a passing problem
// (rate limited, the provider overloaded, the connection dropped before anything came back) is tried again after a
// short, growing wait, honouring the provider's Retry-After, before the turn gives up. Nothing is retried once any part
// of the answer has been handed on, so a retry never repeats a spoken line or a tool call.

/// How hard one kind of provider call is retried.
public struct RetryPolicy: Sendable, Hashable, Codable {
    /// Attempts in all, the first one included. 1 means no retry.
    public var maxAttempts: Int
    /// The wait before the second attempt; each later wait doubles, up to `maxDelay`.
    public var baseDelay: TimeInterval
    /// The longest single wait. A Retry-After longer than this gives up at once instead of waiting.
    public var maxDelay: TimeInterval
    /// The most time spent waiting across all retries of one call.
    public var maxTotalWait: TimeInterval
    /// Each wait is shortened by up to this fraction at random, so callers that failed together don't retry together.
    public var jitter: Double

    public init(maxAttempts: Int, baseDelay: TimeInterval, maxDelay: TimeInterval, maxTotalWait: TimeInterval, jitter: Double = 0.2) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(0, maxDelay)
        self.maxTotalWait = max(0, maxTotalWait)
        self.jitter = min(max(jitter, 0), 1)
    }

    /// No retries.
    public static let none = RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0, maxTotalWait: 0, jitter: 0)
    /// The brain: someone is waiting for the answer, so a few quick tries within about eight seconds.
    public static let brain = RetryPolicy(maxAttempts: 3, baseDelay: 0.6, maxDelay: 5, maxTotalWait: 8)
    /// Speaking a line: the narrator reopens the voice and falls back to the Mac's voice by itself, so one fast retry.
    public static let voice = RetryPolicy(maxAttempts: 2, baseDelay: 0.3, maxDelay: 1.5, maxTotalWait: 1.5)
    /// Opening a listening session while the user holds the talk keys (their audio is buffered meanwhile).
    public static let listening = RetryPolicy(maxAttempts: 2, baseDelay: 0.3, maxDelay: 1.5, maxTotalWait: 1.5)
    /// Opening an always-on realtime session.
    public static let realtime = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, maxDelay: 3, maxTotalWait: 5)
    /// Background text work (cleanup, compaction, memory notes) and agent model checks: nobody is waiting on each word.
    public static let background = RetryPolicy(maxAttempts: 4, baseDelay: 1, maxDelay: 20, maxTotalWait: 45)

    /// The policy each slot uses by default.
    public static func standard(for slot: SlotID) -> RetryPolicy {
        switch slot {
        case .brain: .brain
        case .voice: .voice
        case .stt: .listening
        case .realtimeVoice: .realtime
        case .brainFast, .agent: .background
        }
    }

    /// The wait before attempt number `attempt` (2 for the first retry) after `failure`, or nil to give up.
    /// - Parameters:
    ///   - waited: Time already spent waiting on earlier retries of this call.
    ///   - random: A number in 0..<1 for the jitter.
    public func delay(before attempt: Int, after failure: RetryableFailure, waited: TimeInterval, random: Double) -> TimeInterval? {
        guard attempt >= 2, attempt <= maxAttempts else { return nil }
        let wait: TimeInterval
        if let asked = failure.retryAfter {
            // The provider said when to come back: wait that long or not at all.
            guard asked <= maxDelay else { return nil }
            wait = max(0, asked)
        } else {
            let exponential = baseDelay * pow(2, Double(attempt - 2))
            wait = min(maxDelay, exponential) * (1 - jitter * min(max(random, 0), 1))
        }
        guard waited + wait <= maxTotalWait + 0.000_1 else { return nil }
        return wait
    }
}

/// A failure that may pass if the call is made again.
public struct RetryableFailure: Sendable, Hashable {
    public enum Cause: Sendable, Hashable {
        /// The provider answered with this HTTP status (or refused a WebSocket upgrade with it).
        case status(Int)
        /// The connection failed before any answer came back.
        case network(URLError.Code)
    }

    public var cause: Cause
    /// How long the provider asked to wait (Retry-After, retry-after-ms, or Gemini's retryDelay), when it said.
    public var retryAfter: TimeInterval?

    public init(_ cause: Cause, retryAfter: TimeInterval? = nil) {
        self.cause = cause
        self.retryAfter = retryAfter
    }

    /// Short wording for logs: "HTTP 429", "network (-1005)".
    public var label: String {
        switch cause {
        case .status(let status): "HTTP \(status)"
        case .network(let code): "network error \(code.rawValue)"
        }
    }
}

/// One retry, for logs and the diagnostics bundle.
public struct RetryEvent: Sendable, Hashable {
    public var host: String
    public var attempt: Int
    public var delay: TimeInterval
    public var reason: String

    public init(host: String, attempt: Int, delay: TimeInterval, reason: String) {
        self.host = host
        self.attempt = attempt
        self.delay = delay
        self.reason = reason
    }

    public var description: String {
        "retrying \(host) (attempt \(attempt)) in \(String(format: "%.2f", delay)) s after \(reason)"
    }
}

public enum ProviderRetry {
    /// Statuses that usually pass: timeouts, conflicts, rate limits and overloaded or restarting servers (Anthropic
    /// answers 529 when overloaded; Cloudflare-fronted providers use 520 to 524).
    public static let retryableStatuses: Set<Int> = [408, 409, 425, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524, 529]

    /// Network failures worth one more try. A request timeout is not among them (the request may run for minutes and
    /// would double the wait), nor is "offline" (it won't pass in a second).
    public static let retryableNetworkCodes: Set<URLError.Code> = [.networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed]

    /// Whether an HTTP status (with its body, when known) is worth retrying. A 429 that means the account is out of
    /// quota or credit is not: waiting doesn't refill it.
    public static func isRetryable(status: Int, body: String?) -> Bool {
        guard retryableStatuses.contains(status) else { return false }
        if let body = body?.lowercased(), status == 429 || status == 403 {
            for marker in ["insufficient_quota", "billing", "credit balance", "exceeded your current quota", "quota_exceeded"]
            where body.contains(marker) {
                return false
            }
        }
        return true
    }

    /// The retryable failure behind an error a provider call threw, or nil when it should not be retried.
    /// `ProviderError`s carry the HTTP status of a refused request or WebSocket upgrade.
    public static func classify(_ error: Error) -> RetryableFailure? {
        if error is CancellationError { return nil }
        if let provider = error as? ProviderError, let status = provider.status {
            guard isRetryable(status: status, body: provider.message) else { return nil }
            return RetryableFailure(.status(status), retryAfter: retryDelay(inBody: provider.message))
        }
        if let urlError = error as? URLError, retryableNetworkCodes.contains(urlError.code) {
            return RetryableFailure(.network(urlError.code))
        }
        return nil
    }

    /// The wait a response asks for: `retry-after-ms` (OpenAI), `retry-after` in seconds or as an HTTP date, then a
    /// `"retryDelay": "17s"` in the body (Gemini). Nil when it doesn't say.
    public static func retryAfter(_ response: HTTPURLResponse, body: String? = nil, now: Date = Date()) -> TimeInterval? {
        if let ms = response.value(forHTTPHeaderField: "retry-after-ms").flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), ms >= 0 {
            return ms / 1000
        }
        if let value = response.value(forHTTPHeaderField: "retry-after")?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            if let seconds = Double(value), seconds >= 0 { return seconds }
            if let date = httpDate(value) { return max(0, date.timeIntervalSince(now)) }
        }
        return body.flatMap(retryDelay(inBody:))
    }

    /// Gemini's `"retryDelay": "17s"` (also "1.5s") inside an error body.
    static func retryDelay(inBody body: String) -> TimeInterval? {
        guard let range = body.range(of: #""retryDelay"\s*:\s*"([0-9]+(?:\.[0-9]+)?)s""#, options: .regularExpression) else { return nil }
        let match = String(body[range])
        guard let number = match.range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression) else { return nil }
        return Double(match[number])
    }

    private static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Runs `operation`, trying again on retryable failures as `policy` allows. For opening sessions (a WebSocket
    /// that is refused, a connection that drops during setup), where nothing has been handed on yet.
    public static func run<T: Sendable>(policy: RetryPolicy, host: String,
                                        sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                                        random: @Sendable () -> Double = { Double.random(in: 0..<1) },
                                        onRetry: (@Sendable (RetryEvent) -> Void)? = nil,
                                        _ operation: () async throws -> T) async throws -> T {
        var attempt = 1
        var waited: TimeInterval = 0
        while true {
            do {
                return try await operation()
            } catch {
                guard !Task.isCancelled, let failure = classify(error),
                      let wait = policy.delay(before: attempt + 1, after: failure, waited: waited, random: random()) else { throw error }
                attempt += 1
                waited += wait
                onRetry?(RetryEvent(host: host, attempt: attempt, delay: wait, reason: failure.label))
                try await sleep(wait)
            }
        }
    }
}

/// Retries HTTP requests whose answer never started: a retryable status, or a connection that failed before the
/// response head. Once a response with a usable status is returned, its body streams as it is and is never retried.
///
/// Wraps the transport the engine factory hands to each adapter, so every HTTP adapter (brain, voice, transcription)
/// gets the same behaviour without changing. The error a caller finally sees is the provider's own answer to the
/// last attempt, so adapters word it exactly as before.
public struct RetryingHTTPTransport: HTTPTransport {
    public let base: any HTTPTransport
    public let policy: RetryPolicy
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let random: @Sendable () -> Double
    private let onRetry: (@Sendable (RetryEvent) -> Void)?

    public init(base: any HTTPTransport, policy: RetryPolicy,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
                onRetry: (@Sendable (RetryEvent) -> Void)? = nil) {
        self.base = base
        self.policy = policy
        self.sleep = sleep
        self.random = random
        self.onRetry = onRetry
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await attempt(request) {
            let (data, response) = try await base.data(for: request)
            let body = String(decoding: data.prefix(16_384), as: UTF8.self)
            return ((data, response), response, body)
        }
    }

    public func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        try await stream(for: request, mode: .lines)
    }

    public func stream(for request: URLRequest, mode: HTTPStreamMode) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        try await attempt(request) {
            let (stream, response) = try await base.stream(for: request, mode: mode)
            guard ProviderRetry.retryableStatuses.contains(response.statusCode) else { return ((stream, response), response, nil) }
            // An error answer: read its (short) body to decide, then hand the same bytes on if this is the last try.
            var body = Data()
            for try await chunk in stream {
                body.append(chunk)
                if body.count >= 16_384 { break }
            }
            let replay = AsyncThrowingStream<Data, Error> { continuation in
                if !body.isEmpty { continuation.yield(body) }
                continuation.finish()
            }
            return ((replay, response), response, String(decoding: body, as: UTF8.self))
        }
    }

    private func attempt<T>(_ request: URLRequest,
                            _ send: () async throws -> (value: T, response: HTTPURLResponse, body: String?)) async throws -> T {
        let host = request.url?.host ?? "provider"
        var attempt = 1
        var waited: TimeInterval = 0
        while true {
            let failure: RetryableFailure
            let outcome: Result<T, Error>
            do {
                let (value, response, body) = try await send()
                guard ProviderRetry.isRetryable(status: response.statusCode, body: body) else { return value }
                failure = RetryableFailure(.status(response.statusCode), retryAfter: ProviderRetry.retryAfter(response, body: body))
                outcome = .success(value)
            } catch {
                guard let classified = ProviderRetry.classify(error) else { throw error }
                failure = classified
                outcome = .failure(error)
            }
            guard !Task.isCancelled,
                  let wait = policy.delay(before: attempt + 1, after: failure, waited: waited, random: random()) else {
                return try outcome.get()
            }
            attempt += 1
            waited += wait
            onRetry?(RetryEvent(host: host, attempt: attempt, delay: wait, reason: failure.label))
            try await sleep(wait)
        }
    }
}
