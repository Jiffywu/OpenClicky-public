import Foundation

// The voice loop's side of retries, plain explanations and usage: which surface a turn's records belong to, and the
// notch notice for listening that couldn't start.

extension UsageSurface {
    /// The surface for a turn of this kind.
    public static func forTurn(_ kind: TurnKind) -> UsageSurface {
        switch kind {
        case .voice: .voiceTurn
        case .typed: .typedTurn
        case .report: .reportTurn
        case .guided: .guidedTurn
        }
    }
}

extension TurnNotice {
    /// Listening failed during a press. A diagnosed provider failure says why in plain words (region, blocked network,
    /// offline, key, outage); a usage limit says so; anything else is a dropped connection.
    public static func listeningFailed(_ error: Error) -> TurnNotice {
        if let unavailable = error as? ProviderUnavailableError {
            return TurnNotice(.warning, unavailable.diagnosis.headline, detail: unavailable.diagnosis.explanation)
        }
        if let limit = error as? UsageLimitError {
            return TurnNotice(.warning, "Usage limit reached.", detail: limit.description)
        }
        let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return .connectionDropped(detail)
    }
}

extension BrainSessionStats {
    /// Stats built outside the runtime (evidence renders and tests of the Developer page).
    public static func make(sessionID: String, startedAt: Date, lastTurnAt: Date?, turns: Int, threadItems: Int, screenshotsInThread: Int,
                            lastInputTokens: Int, nextCompactionCheck: Int, compactions: Int) -> BrainSessionStats {
        BrainSessionStats(sessionID: sessionID, startedAt: startedAt, lastTurnAt: lastTurnAt, turns: turns, threadItems: threadItems,
                          screenshotsInThread: screenshotsInThread, lastInputTokens: lastInputTokens,
                          nextCompactionCheck: nextCompactionCheck, compactions: compactions)
    }
}
