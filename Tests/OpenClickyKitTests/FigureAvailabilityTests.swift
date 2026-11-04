import Foundation
import Testing
@testable import OpenClickyKit

// The "3D unavailable" verdict is kept per build: the same build knows at launch, a new build tries again, and a
// compile that never finished counts as a failure.

private func store(_ build: String) -> (FigureAvailability.Store, UserDefaults, String) {
    let suite = "openclicky.tests.figures.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return (FigureAvailability.Store(defaults: defaults, build: build), defaults, suite)
}

@Suite struct FigureAvailabilityTests {
    @Test func aFailureIsRememberedForTheSameBuildOnly() {
        let (first, defaults, suite) = store("1.0 (7) 1730000000")
        defer { defaults.removePersistentDomain(forName: suite) }
        let launch1 = FigureAvailability(hasDevice: { true }, store: first)
        #expect(launch1.isAvailable)
        launch1.markUnavailable("3D shaders failed to compile: test")

        // The next launch of the same build knows without compiling.
        let launch2 = FigureAvailability(hasDevice: { true }, store: first)
        #expect(launch2.problem == "3D shaders failed to compile: test")
        let reported = Locked<String?>(nil)
        launch2.warmUp { reported.set($0) }
        #expect(reported.get() == "3D shaders failed to compile: test")

        // A new build starts fresh.
        let newer = FigureAvailability.Store(defaults: defaults, build: "1.0 (8) 1730009999")
        #expect(FigureAvailability(hasDevice: { true }, store: newer).isAvailable)
    }

    @Test func aCompileThatNeverFinishedCountsAsAFailure() {
        let (build, defaults, suite) = store("2.0 (1) 1730000000")
        defer { defaults.removePersistentDomain(forName: suite) }
        // The previous launch noted it started compiling, then died.
        defaults.set(build.build, forKey: FigureAvailability.Store.pendingKey)
        let launch = FigureAvailability(hasDevice: { true }, store: build)
        #expect(!launch.isAvailable)
        #expect(launch.problem?.contains("didn't finish compiling") == true)
        // Kept as this build's verdict.
        #expect(FigureAvailability(hasDevice: { true }, store: build).isAvailable == false)
        launch.reset()
        #expect(FigureAvailability(hasDevice: { true }, store: build).isAvailable)
    }

    @Test func aFinishedWarmUpClearsItsPendingNote() async {
        let (build, defaults, suite) = store("3.0 (1) 1730000000")
        defer { defaults.removePersistentDomain(forName: suite) }
        let availability = FigureAvailability(store: build)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            availability.warmUp { _ in done.resume() }
        }
        // The studio compile reports last; wait for it to clear the note.
        _ = await waitUntil(.seconds(30)) { defaults.string(forKey: FigureAvailability.Store.pendingKey) == nil }
        #expect(defaults.string(forKey: FigureAvailability.Store.pendingKey) == nil)
        #expect(availability.isAvailable)
        #expect(FigureAvailability(store: build).isAvailable)
    }

    @Test func aCleanQuitDuringTheCompileDoesNotTurn3DOff() {
        let (build, defaults, suite) = store("4.0 (1) 1730000000")
        defer { defaults.removePersistentDomain(forName: suite) }
        let launch = FigureAvailability(hasDevice: { true }, store: build)
        // The warm-up noted it started compiling, and the user quits before the studio shaders report.
        defaults.set(build.build, forKey: FigureAvailability.Store.pendingKey)
        launch.appWillTerminate()
        #expect(defaults.string(forKey: FigureAvailability.Store.pendingKey) == nil)
        #expect(FigureAvailability(hasDevice: { true }, store: build).isAvailable)
    }

    @MainActor
    @Test func aStageThatCouldNotMakeAGPUObjectCountsOnlyUntilQuit() async throws {
        let (build, defaults, suite) = store("5.0 (1) 1730000000")
        defer { defaults.removePersistentDomain(forName: suite) }
        func failingStage(_ error: FigureRendererError) async throws -> FigureStage {
            let harness = try FigureProgramHarness()
            harness.run(#"const f = figure(0, 0, 300, 300, { spin: 0 }); f.box({ size: [1, 1, 1] });"#)
            let stage = FigureStage(kernel: FigureKernel(byteBudget: 32 << 20), drivesItself: false, clock: { 0 })
            stage.makeRenderer = { _ in throw error }
            for mark in harness.marks where mark.isFigureMark { stage.apply(mark) }
            await stage.settle()
            return stage
        }

        let transient = try await failingStage(.resources("command queue"))
        #expect(transient.rendererError != nil)
        let launch1 = FigureAvailability(hasDevice: { true }, store: build)
        launch1.record(transient)
        #expect(!launch1.isAvailable)
        // The next launch of the same build tries again.
        #expect(FigureAvailability(hasDevice: { true }, store: build).isAvailable)

        // A pipeline that doesn't build fails the same way every time: kept for the build.
        let broken = try await failingStage(.pipeline("figure_vertex: test"))
        let launch2 = FigureAvailability(hasDevice: { true }, store: build)
        launch2.record(broken)
        #expect(!launch2.isAvailable)
        #expect(FigureAvailability(hasDevice: { true }, store: build).isAvailable == false)
    }

    @Test func outsideAnAppBundleNothingIsKept() {
        #expect(FigureAvailability.Store.appDefaults(bundle: Bundle(for: BundleProbe.self)) == nil)
    }
}

private final class BundleProbe {}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ new: Value) { lock.withLock { value = new } }
    func get() -> Value { lock.withLock { value } }
}
