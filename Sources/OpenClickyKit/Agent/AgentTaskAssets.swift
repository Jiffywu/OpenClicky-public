import Foundation

/// What the voice turn that started a job had: the screenshots the brain saw and files the user attached.
public struct AgentTurnAssets: Sendable, Hashable {
    /// Brain tools inherit the launching turn's assets even if another turn captures a screen meanwhile.
    @TaskLocal static var forBrainTurn: AgentTurnAssets?
    /// JPEG screenshots, the one under the pointer first.
    public var screenshots: [Data]
    /// Files the user attached (absolute paths); passed to the agent by path as inputs, never copied.
    public var attachments: [URL]
    public var capturedAt: Date

    public init(screenshots: [Data] = [], attachments: [URL] = [], capturedAt: Date = Date()) {
        self.screenshots = screenshots
        self.attachments = attachments
        self.capturedAt = capturedAt
    }

    public var isEmpty: Bool { screenshots.isEmpty && attachments.isEmpty }
}

/// The latest turn's assets, recorded by the voice loop as each turn captures the screen and read by `sessions_spawn`
/// while that turn runs. Thread-safe.
public final class AgentTurnAssetsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: AgentTurnAssets?

    public init() {}

    public func record(_ assets: AgentTurnAssets) { lock.withLock { latest = assets } }

    public func clear() { lock.withLock { latest = nil } }

    /// The latest assets if they are recent enough to belong to the turn calling the tool.
    public func current(now: Date = Date(), maxAge: TimeInterval = 180) -> AgentTurnAssets? {
        lock.withLock {
            guard let latest, now.timeIntervalSince(latest.capturedAt) <= maxAge else { return nil }
            return latest
        }
    }
}

/// Where a run's screenshots and images are kept: `harness/task-assets/<job id>/run-<n>/screen-<i>.jpg` under the
/// support folder, outside the job folder so they never look like deliverables. Removed with the job's other
/// scratch by the cleanup after `AgentLimits.cleanupAfterDays`.
public enum AgentTaskAssets {
    public static func folder(paths: AgentPaths, jobID: String, run: Int) -> URL {
        paths.taskAssets.appendingPathComponent(jobID, isDirectory: true).appendingPathComponent("run-\(run)", isDirectory: true)
    }

    /// Saves the screenshots (and copies the given images) for a run; returns the saved files in order.
    public static func save(screenshots: [Data], images: [URL], paths: AgentPaths, jobID: String, run: Int) throws -> [URL] {
        guard !screenshots.isEmpty || !images.isEmpty else { return [] }
        let folder = folder(paths: paths, jobID: jobID, run: run)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var saved: [URL] = []
        for (index, data) in screenshots.enumerated() {
            let url = folder.appendingPathComponent("screen-\(index + 1).jpg")
            try data.write(to: url, options: .atomic)
            saved.append(url)
        }
        for (index, image) in images.enumerated() {
            let ext = image.pathExtension.isEmpty ? "jpg" : image.pathExtension.lowercased()
            let url = folder.appendingPathComponent("image-\(index + 1).\(ext)")
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: image, to: url)
            saved.append(url)
        }
        return saved
    }
}

extension AgentPaths {
    /// Screenshots and images given to jobs at launch, one folder per job and run.
    public var taskAssets: URL { root.appendingPathComponent("harness/task-assets", isDirectory: true) }
}
