import Foundation

/// A drive the brain proposed, shown on the consent card.
public struct TakeoverOffer: Sendable, Hashable {
    public var id: String
    public var brief: TakeoverBrief
    public var offeredAt: Date

    public init(id: String, brief: TakeoverBrief, offeredAt: Date) {
        self.id = id
        self.brief = brief
        self.offeredAt = offeredAt
    }
}

/// Where the user's yes came from. The model can never be a source: the brain tools only offer, start an approved
/// drive, or stop.
public enum TakeoverConsentSource: Sendable, Hashable {
    /// The user clicked the card's drive button or pressed Return on it.
    case card
    /// The user's own reply, as transcribed or typed, while the card was up. It must read as a clear yes.
    case userReply(String)
}

/// Where the take-over flow is.
public enum TakeoverPhase: Sendable, Hashable {
    case idle
    /// The card is up, waiting for the user.
    case offered(TakeoverOffer)
    /// The user said yes; the drive may start (once) until the approval expires.
    case approved(TakeoverOffer, at: Date)
    case driving(TakeoverOffer)
    /// A stop was requested; the drive is winding down.
    case stopping(TakeoverOffer, TakeoverStopReason)

    public var name: String {
        switch self {
        case .idle: "idle"
        case .offered: "offered"
        case .approved: "approved"
        case .driving: "driving"
        case .stopping: "stopping"
        }
    }

    public var offer: TakeoverOffer? {
        switch self {
        case .idle: nil
        case .offered(let offer), .approved(let offer, _), .driving(let offer), .stopping(let offer, _): offer
        }
    }

    public var isDriving: Bool {
        switch self {
        case .driving, .stopping: true
        default: false
        }
    }
}

public enum TakeoverConsentError: Error, Sendable, Hashable, CustomStringConvertible {
    case emptyTask
    case alreadyDriving
    case noOffer
    /// The answer is for an older card than the one showing.
    case staleOffer
    case offerExpired
    case notApproved
    case approvalExpired
    /// The user's reply did not read as a clear yes.
    case notAffirmative

    public var description: String {
        switch self {
        case .emptyTask: "The offer needs a task."
        case .alreadyDriving: "A drive is already running."
        case .noOffer: "There is no take-over offer waiting for an answer."
        case .staleOffer: "That answer is for an earlier offer."
        case .offerExpired: "The offer expired before the user answered."
        case .notApproved: "The user has not said yes to the take-over."
        case .approvalExpired: "The user's yes expired before the drive started; offer again."
        case .notAffirmative: "The user's reply was not a clear yes."
        }
    }
}

/// The consent rules, as a pure state machine (the controller adds the side effects):
///
/// idle → offer → offered → (card or the user's clear yes) → approved → beginDrive → driving → requestStop →
/// stopping → finish → idle. Declining, expiry, end_screen_takeover before the start, or a new offer return an
/// offer to idle or replace it. An approval is good for one drive, for `approvalLifetime` seconds; an offer stays
/// up for `offerLifetime` seconds.
public struct TakeoverConsentMachine: Sendable, Hashable {
    public private(set) var phase: TakeoverPhase = .idle
    public var offerLifetime: TimeInterval
    public var approvalLifetime: TimeInterval
    public private(set) var lastOutcome: TakeoverOutcome?

    public init(offerLifetime: TimeInterval = 180, approvalLifetime: TimeInterval = 90) {
        self.offerLifetime = offerLifetime
        self.approvalLifetime = approvalLifetime
    }

    /// Puts up a new offer, replacing any offer or approval that has not started. Refused while a drive runs.
    public mutating func offer(_ brief: TakeoverBrief, id: String, now: Date) throws(TakeoverConsentError) -> TakeoverOffer {
        guard !phase.isDriving else { throw .alreadyDriving }
        guard !brief.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptyTask }
        let offer = TakeoverOffer(id: id, brief: brief, offeredAt: now)
        phase = .offered(offer)
        return offer
    }

    /// Records the user's yes. `offerID` (when given) must name the offer showing. A reply must read as a clear yes.
    public mutating func approve(offerID: String? = nil, source: TakeoverConsentSource, now: Date) throws(TakeoverConsentError) -> TakeoverOffer {
        expireIfNeeded(now: now)
        let offer: TakeoverOffer
        switch phase {
        case .offered(let current): offer = current
        case .approved(let current, _): offer = current
        case .driving, .stopping: throw .alreadyDriving
        case .idle: throw lastExpired ? TakeoverConsentError.offerExpired : TakeoverConsentError.noOffer
        }
        if let offerID, offerID != offer.id { throw .staleOffer }
        if case .userReply(let words) = source, !TakeoverReplyConsent.isClearYes(words) { throw .notAffirmative }
        phase = .approved(offer, at: now)
        lastExpired = false
        return offer
    }

    /// The user said no (or closed the card). Returns the withdrawn offer.
    @discardableResult
    public mutating func decline(offerID: String? = nil) -> TakeoverOffer? {
        switch phase {
        case .offered(let offer), .approved(let offer, _):
            if let offerID, offerID != offer.id { return nil }
            phase = .idle
            return offer
        default:
            return nil
        }
    }

    /// Starts the approved drive, consuming the approval.
    public mutating func beginDrive(now: Date) throws(TakeoverConsentError) -> TakeoverOffer {
        expireIfNeeded(now: now)
        switch phase {
        case .approved(let offer, _):
            phase = .driving(offer)
            return offer
        case .offered: throw .notApproved
        case .driving, .stopping: throw .alreadyDriving
        case .idle: throw lastExpired ? TakeoverConsentError.approvalExpired : TakeoverConsentError.noOffer
        }
    }

    /// Asks a running drive to stop. False when nothing is driving (or a stop is already under way).
    @discardableResult
    public mutating func requestStop(_ reason: TakeoverStopReason) -> Bool {
        guard case .driving(let offer) = phase else { return false }
        phase = .stopping(offer, reason)
        return true
    }

    /// The drive ended.
    public mutating func finish(_ outcome: TakeoverOutcome) {
        guard phase.isDriving else { return }
        phase = .idle
        lastOutcome = outcome
    }

    /// Drops an offer or approval that has outlived its lifetime. True when one expired.
    @discardableResult
    public mutating func expireIfNeeded(now: Date) -> Bool {
        switch phase {
        case .offered(let offer) where now.timeIntervalSince(offer.offeredAt) > offerLifetime,
             .approved(let offer, _) where now.timeIntervalSince(offer.offeredAt) > offerLifetime:
            phase = .idle
            lastExpired = true
            return true
        case .approved(_, let at) where now.timeIntervalSince(at) > approvalLifetime:
            phase = .idle
            lastExpired = true
            return true
        default:
            return false
        }
    }

    private var lastExpired = false
}

/// Reads a user's reply to the consent question. Only a short, clear yes counts: the reply must hold a yes phrase
/// and be made only of words that agree ("yes please", "sure, go for it", "fine by me"). A yes word inside some
/// other sentence ("I'll do it myself", "you can see the button", "ok so where is Save") is not consent, nor is
/// anything with a no, a hedge or a question in it; the user is asked again or uses the card. Missing a real yes
/// costs one more question, while reading a yes that was not meant would let OpenClicky act without consent.
public enum TakeoverReplyConsent {
    static let yesPhrases: [String] = [
        "yes", "yeah", "yep", "yup", "yah", "sure", "ok", "okay", "go ahead", "go for it", "do it", "please do", "sounds good",
        "take over", "drive", "you can", "let's do it", "lets do it", "absolutely", "of course", "alright", "all right", "fine",
        "definitely", "please",
    ]
    /// Every word a clear yes may contain. Anything else makes the reply unclear.
    static let consentWords: Set<String> = [
        "yes", "yeah", "yep", "yup", "yah", "ya", "sure", "ok", "okay", "k", "alright", "all", "right", "fine", "go", "ahead",
        "for", "it", "do", "please", "pls", "plz", "thanks", "thank", "you", "sounds", "good", "great", "perfect", "absolutely",
        "definitely", "totally", "of", "course", "let's", "lets", "take", "over", "drive", "can", "that", "that's", "thats",
        "would", "be", "nice", "awesome", "cool", "by", "me", "to", "and", "just", "now", "oh", "uh", "um", "thing",
    ]
    static let noWords: Set<String> = [
        "no", "nope", "nah", "don't", "dont", "not", "never", "stop", "wait", "cancel", "hold", "later", "maybe",
        "hmm", "actually", "instead", "but", "without", "shouldn't", "can't", "cannot", "won't",
    ]

    public static func isClearYes(_ reply: String) -> Bool {
        let lowered = reply.lowercased().replacingOccurrences(of: "’", with: "'")
        if lowered.contains("?") { return false }
        let words = lowered.split { !($0.isLetter || $0 == "'") }.map(String.init)
        guard !words.isEmpty, words.count <= 12 else { return false }
        if words.contains(where: noWords.contains) { return false }
        guard words.allSatisfy(consentWords.contains) else { return false }
        let joined = " " + words.joined(separator: " ") + " "
        return yesPhrases.contains { joined.contains(" \($0) ") }
    }
}
