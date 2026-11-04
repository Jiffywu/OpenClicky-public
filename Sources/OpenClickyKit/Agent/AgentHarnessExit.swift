import Foundation

/// Recognizes the error a harness reports when its process exits in the middle of a turn ("Codex stopped (exit 9)",
/// "Claude Code stopped (exit 1): …"), as opposed to a turn the model itself failed. The manager restarts the harness
/// once for these and resumes the conversation.
public enum AgentHarnessExit {
    private static let pattern = try! NSRegularExpression(pattern: #"^(?:Codex|Claude Code) stopped \(exit -?\d+\)"#)

    public static func isExit(_ error: String) -> Bool {
        pattern.firstMatch(in: error, range: NSRange(error.startIndex..., in: error)) != nil
    }
}
