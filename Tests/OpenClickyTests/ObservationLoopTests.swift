import Foundation
import Observation
import Testing
@testable import OpenClicky

@Observable @MainActor private final class Counted {
    var value = 0
}

@Suite @MainActor struct ObservationLoopTests {
    /// The notch refreshes its activity by hand on every take-over step. Each refresh must replace the pending
    /// observation, or every step adds a chain that re-runs on every later change.
    @Test func refreshingByHandKeepsOneObservation() async {
        let state = Counted()
        var reads = 0
        var applied: [Int] = []
        let loop = ObservationLoop(read: { () -> Int in
            reads += 1
            return state.value
        }, apply: { applied.append($0) })
        for _ in 0..<30 { loop.refresh() }
        #expect(reads == 30)
        state.value = 1
        #expect(await Self.eventually { applied.last == 1 })
        // Let any extra chains run before counting.
        for _ in 0..<20 { await Task.yield() }
        #expect(reads == 31, "one change re-reads once, not once per earlier refresh")
        state.value = 2
        #expect(await Self.eventually { applied.last == 2 })
        for _ in 0..<20 { await Task.yield() }
        #expect(reads == 32)

        loop.cancel()
        state.value = 3
        for _ in 0..<20 { await Task.yield() }
        #expect(reads == 32 && applied.last == 2, "a cancelled loop stops reacting")
    }

    static func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}
