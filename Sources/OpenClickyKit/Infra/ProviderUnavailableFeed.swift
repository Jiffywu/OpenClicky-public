import Foundation
import os

/// Every `ProviderUnavailableError` the installed provider layer explains, handed to whoever listens (the notch's
/// "isn't answering" card). Process-wide, because the errors are made deep inside engines that know nothing of the UI.
public enum ProviderUnavailableFeed {
    public typealias Handler = @Sendable (ProviderUnavailableError) -> Void

    private static let handlers = OSAllocatedUnfairLock<[UUID: Handler]>(initialState: [:])

    /// Starts listening; keep the token to stop.
    @discardableResult
    public static func subscribe(_ handler: @escaping Handler) -> UUID {
        let id = UUID()
        handlers.withLock { $0[id] = handler }
        return id
    }

    public static func unsubscribe(_ id: UUID) { _ = handlers.withLock { $0.removeValue(forKey: id) } }

    public static func publish(_ error: ProviderUnavailableError) {
        for handler in handlers.withLock({ Array($0.values) }) { handler(error) }
    }
}
