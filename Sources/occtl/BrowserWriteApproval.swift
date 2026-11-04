import Foundation
import OpenClickyKit

enum BrowserWriteApproval {
    private static let queue = DispatchQueue(label: "occtl.browser-approval")

    static func ask(_ request: BrowserChangeRequest) async -> Bool {
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard !cancellation.isCancelled, isatty(STDIN_FILENO) == 1 else {
                        continuation.resume(returning: false)
                        return
                    }
                    let id = UUID().uuidString.lowercased()
                    let prompt: JSONValue = ["id": .string(id), "job_id": request.jobID.map(JSONValue.string) ?? .null,
                                             "operation": .string(request.operation), "arguments": request.arguments]
                    print(request.summary)
                    print(request.details)
                    print("[browser-approval] \(prompt.jsonString())")
                    print("Type ALLOW \(id) to approve this action once. Any other answer declines; expires in two minutes.")
                    fflush(stdout)
                    let deadline = Date().addingTimeInterval(120)
                    while !cancellation.isCancelled, Date() < deadline {
                        var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                        let ready = poll(&input, 1, 250)
                        if ready > 0 {
                            let answer = input.revents & Int16(POLLIN) != 0 ? readLine() : nil
                            continuation.resume(returning: !cancellation.isCancelled && answer == "ALLOW \(id)")
                            return
                        }
                        if ready < 0, errno != EINTR { break }
                    }
                    continuation.resume(returning: false)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
}
