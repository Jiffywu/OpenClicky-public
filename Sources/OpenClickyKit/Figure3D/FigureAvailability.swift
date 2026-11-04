import Foundation
import Metal

/// Whether this Mac can show 3D figures right now: a Metal device exists, the figure shaders compiled, and no stage's
/// renderer has failed. The brain's prompt reads it (`BrainContextSources.figuresAvailable`), so the brain is told
/// not to call `figure()` when figures would come out blank.
///
/// `warmUp()` compiles the shaders in the background at launch, so the first figure doesn't stall and a compile
/// failure is known before the brain is asked.
///
/// A verdict that figures can't work is kept per build (`Store`): the next launch of the same build knows at once and
/// doesn't compile again. That also covers a compile that never finished: the warm-up notes that it started, and a
/// launch that finds the note still there (the app died while compiling, e.g. a GPU driver crash) treats 3D as
/// unavailable instead of trying again. A normal quit during the compile clears the note (`appWillTerminate()`), and
/// a GPU object that couldn't be made counts only until the app quits. A new build starts fresh.
public final class FigureAvailability: @unchecked Sendable {
    public static let shared = FigureAvailability(store: Store.appDefaults())

    /// Where the per-build verdict is kept.
    /// UserDefaults is thread-safe, so the store can cross threads.
    public struct Store: @unchecked Sendable {
        public var defaults: UserDefaults
        /// Identifies this build: version, build number and the executable's modification date.
        public var build: String
        public static let verdictKey = "figures3D.unavailable"
        public static let pendingKey = "figures3D.compilePending"

        public init(defaults: UserDefaults, build: String) {
            self.defaults = defaults
            self.build = build
        }

        /// The app's own defaults, keyed by this build. Nil outside an app bundle (occtl, tests), which keep nothing.
        public static func appDefaults(bundle: Bundle = .main) -> Store? {
            guard bundle.bundleURL.pathExtension == "app" else { return nil }
            return Store(defaults: .standard, build: buildKey(bundle: bundle))
        }

        public static func buildKey(bundle: Bundle = .main) -> String {
            let info = bundle.infoDictionary ?? [:]
            let version = info["CFBundleShortVersionString"] as? String ?? "?"
            let number = info["CFBundleVersion"] as? String ?? "?"
            let modified = bundle.executableURL
                .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
                .map { String(Int($0.timeIntervalSince1970)) } ?? "?"
            return "\(version) (\(number)) \(modified)"
        }

        /// The reason recorded for this build, if any (another build's verdict is ignored).
        var verdict: String? {
            guard let entry = defaults.dictionary(forKey: Self.verdictKey), entry["build"] as? String == build else { return nil }
            return entry["reason"] as? String
        }

        func record(_ reason: String) { defaults.set(["build": build, "reason": reason], forKey: Self.verdictKey) }

        var compileWasPending: Bool { defaults.string(forKey: Self.pendingKey) == build }
        func setCompilePending(_ pending: Bool) {
            if pending { defaults.set(build, forKey: Self.pendingKey) } else { defaults.removeObject(forKey: Self.pendingKey) }
        }

        func clear() {
            defaults.removeObject(forKey: Self.verdictKey)
            defaults.removeObject(forKey: Self.pendingKey)
        }
    }

    private let lock = NSLock()
    private let hasDevice: @Sendable () -> Bool
    private let store: Store?
    private var deviceChecked: Bool?
    private var failure: String?
    private var studioFailure: String?

    /// - Parameters:
    ///   - hasDevice: whether a Metal device exists (tests pass a fake).
    ///   - store: where the per-build verdict is kept; nil keeps nothing.
    public init(hasDevice: @escaping @Sendable () -> Bool = { MTLCreateSystemDefaultDevice() != nil }, store: Store? = nil) {
        self.hasDevice = hasDevice
        self.store = store
        if let store {
            if let reason = store.verdict {
                failure = reason
            } else if store.compileWasPending {
                let reason = "3D shaders didn't finish compiling the last time this build ran, so 3D stays off for this build"
                failure = reason
                store.record(reason)
            }
        }
    }

    /// True until something showed figures can't work here.
    public var isAvailable: Bool { problem == nil }

    /// Why figures can't be shown, or nil.
    public var problem: String? {
        let (checked, failure) = lock.withLock { (deviceChecked, self.failure) }
        if let failure { return failure }
        let device = checked ?? {
            let found = hasDevice()
            lock.withLock { deviceChecked = found }
            return found
        }()
        return device ? nil : FigureRendererError.noDevice.description
    }

    /// Why the studio look can't be drawn (figures then use the illustrated look), or nil.
    public var studioProblem: String? { lock.withLock { studioFailure } }

    /// Compiles the figure shaders off the main thread; a failure marks figures unavailable. `completion` gets the
    /// problem (nil when they compiled). A build already known to fail doesn't compile again.
    public func warmUp(device: MTLDevice? = nil, completion: (@Sendable (String?) -> Void)? = nil) {
        if let known = lock.withLock({ failure }) {
            completion?(known)
            return
        }
        store?.setCompilePending(true)
        FigureRenderer.warmUpShaders(device: device, completion: { [weak self] error in
            if let error { self?.markUnavailable((error as? FigureRendererError)?.description ?? "3D shaders failed to compile: \(error)") }
            completion?(error.map { ($0 as? FigureRendererError)?.description ?? "\($0)" })
        }, studio: { [weak self] error in
            // Studio is compiled last: once it reports, the compile is over either way.
            self?.store?.setCompilePending(false)
            if let error { self?.lock.withLock { self?.studioFailure = (error as? FigureRendererError)?.description ?? "\(error)" } }
        })
    }

    /// A stage's renderer failed (`FigureStage.rendererError`) or the shaders didn't compile. Remembered for this build
    /// unless `persist` is false (a failure that may not happen again, which lasts until the app quits).
    public func markUnavailable(_ reason: String, persist: Bool = true) {
        let first = lock.withLock { () -> Bool in
            guard failure == nil else { return false }
            failure = reason
            return true
        }
        if first, persist { store?.record(reason) }
    }

    /// Reads a stage's renderer error, if it has one. Shader and pipeline failures repeat on every launch of a build,
    /// so they are remembered; a GPU object that couldn't be made (`.resources`, e.g. a command queue under memory
    /// pressure) counts only until the app quits.
    @MainActor
    public func record(_ stage: FigureStage) {
        guard let error = stage.rendererError else { return }
        let transient = if case .resources = error as? FigureRendererError { true } else { false }
        markUnavailable((error as? FigureRendererError)?.description ?? "\(error)", persist: !transient)
    }

    /// The app is quitting normally. A compile still running is not a crash, so its note is cleared and the next
    /// launch compiles again instead of turning 3D off for the build.
    public func appWillTerminate() {
        store?.setCompilePending(false)
    }

    /// Clears a failure and the per-build verdict (tests; after a GPU change).
    public func reset() {
        lock.withLock {
            failure = nil
            studioFailure = nil
            deviceChecked = nil
        }
        store?.clear()
    }
}
