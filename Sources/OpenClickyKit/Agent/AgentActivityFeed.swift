import Foundation

/// What the agent HUD shows, folded from the manager's updates: every job (newest first), a few live progress lines
/// per job, its current plan, and which jobs have a harness running. A value type, so the HUD model on the main
/// actor just applies updates and SwiftUI redraws.
public struct AgentActivityFeed: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public var record: AgentJobRecord
        /// Newest last; at most `AgentActivityFeed.linesPerJob`.
        public var lines: [String]
        public var plan: [AgentPlanStep]
        /// Files the agent touched in the current run, newest last (absolute paths).
        public var touchedFiles: [String]
        public var lastReport: AgentJobReport?

        public var id: String { record.id }

        /// The line to show under the title: the live progress while working, else the spoken result or error.
        public var headline: String {
            if record.status.isActive {
                if let request = record.pendingRequest { return "Needs a yes: \(request.summary)" }
                if let step = record.waitingStep, record.status == .needsYou { return "Waiting for you: \(step.step)" }
                if let question = record.report?.question, record.status == .needsYou { return question }
                return lines.last ?? record.lastProgress ?? "Starting"
            }
            if record.status == .failed { return record.error.map { AgentText.firstLine($0, limit: 160) } ?? "Failed" }
            return lastReport?.spoken ?? record.report?.spoken.nilIfEmpty ?? record.lastProgress ?? record.status.rawValue
        }

        /// Completed plan steps over all steps, for a progress bar; nil without a plan.
        public var planProgress: Double? {
            guard !plan.isEmpty else { return nil }
            return Double(plan.filter { $0.status == .completed }.count) / Double(plan.count)
        }
    }

    public static let linesPerJob = 6
    public static let maxItems = 50

    public private(set) var items: [Item] = []

    public init(records: [AgentJobRecord] = []) {
        items = records.prefix(Self.maxItems).map { Item(record: $0, lines: [], plan: [], touchedFiles: [], lastReport: nil) }
    }

    public var active: [Item] { items.filter { $0.record.status.isActive } }
    public var needsYouCount: Int { items.filter { $0.record.status == .needsYou }.count }

    public func item(_ id: String) -> Item? { items.first { $0.id == id } }

    public mutating func apply(_ update: AgentManagerUpdate) {
        switch update {
        case .job(let record):
            if let index = items.firstIndex(where: { $0.id == record.id }) {
                let startedNewRun = record.runs.count > items[index].record.runs.count
                items[index].record = record
                if startedNewRun {
                    items[index].lines = []
                    items[index].plan = []
                    items[index].touchedFiles = []
                }
                // Most recently updated first.
                let item = items.remove(at: index)
                items.insert(item, at: 0)
            } else {
                items.insert(Item(record: record, lines: [], plan: [], touchedFiles: [], lastReport: nil), at: 0)
                if items.count > Self.maxItems { items.removeLast(items.count - Self.maxItems) }
            }
        case .event(let jobID, let event):
            guard let index = items.firstIndex(where: { $0.id == jobID }) else { return }
            switch event {
            case .plan(let steps):
                items[index].plan = steps
            case .fileChanged(let path, _):
                items[index].touchedFiles.removeAll { $0 == path }
                items[index].touchedFiles.append(path)
                if items[index].touchedFiles.count > 20 { items[index].touchedFiles.removeFirst() }
            case .turnStarted:
                items[index].plan = []
            default:
                break
            }
            if let line = event.progressLine, items[index].lines.last != line {
                items[index].lines.append(line)
                if items[index].lines.count > Self.linesPerJob { items[index].lines.removeFirst(items[index].lines.count - Self.linesPerJob) }
            }
        case .report(let report):
            guard let index = items.firstIndex(where: { $0.id == report.jobID }) else { return }
            items[index].lastReport = report
        case .launched(let record):
            apply(.job(record))
        }
    }
}
