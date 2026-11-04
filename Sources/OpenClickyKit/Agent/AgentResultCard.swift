import Foundation

/// What a job's result card shows, worked out from its report: the app's card view only lays it out. Next steps
/// become follow-up chips; tapping one sends its text to the same job (`followUp(for:)`).
public struct AgentResultCard: Sendable, Hashable, Identifiable {
    public struct File: Sendable, Hashable, Identifiable {
        /// An absolute path or a web link.
        public var location: String
        /// The file's name, or a link's host and path.
        public var name: String
        public var isLink: Bool
        public var id: String { location }
    }

    public var id: String { report.id }
    public var report: AgentJobReport
    public var title: String
    /// Who did it, how it went and how long it took ("Research Buddy · done · 2 min").
    public var subtitle: String
    /// The spoken line, shown as the card's lead.
    public var summary: String
    /// The report body (markdown), without citation leftovers.
    public var body: String
    public var files: [File]
    /// At most three, each short enough for a chip.
    public var chips: [String]
    public var question: String?
    /// An SF Symbol for the deliverable kind.
    public var symbol: String
    /// The structured answer (numbers, a list, receipts, a draft, choices), when the agent gave one.
    public var answer: AgentAnswer?
    /// A step the user has to do; the card offers "I'm done".
    public var userStep: AgentUserStep?
    /// Routines the agent proposed; the card asks to set them up.
    public var routineProposals: [AgentRoutineRequest]

    public init(report: AgentJobReport) {
        self.report = report
        title = report.title
        var parts: [String] = []
        if let agent = report.agentName { parts.append(agent) }
        let outcome: String = switch report.outcome {
        case .done: "done"
        case .needsYou: "needs you"
        case .failed: "didn't finish"
        case .stopped: "stopped"
        }
        parts.append(outcome)
        parts.append(Self.duration(report.durationSeconds))
        subtitle = parts.joined(separator: " · ")
        summary = AgentText.stripCitations(report.spoken)
        body = AgentText.stripCitations(report.markdown).trimmingCharacters(in: .whitespacesAndNewlines)
        files = report.files.prefix(6).map { location in
            if location.hasPrefix("http://") || location.hasPrefix("https://"), let url = URL(string: location) {
                let path = url.path == "/" ? "" : url.path
                return File(location: location, name: AgentText.shorten((url.host ?? location) + path, limit: 60), isLink: true)
            }
            return File(location: location, name: URL(fileURLWithPath: location).lastPathComponent, isLink: false)
        }
        chips = Self.chips(from: report.nextSteps)
        question = report.outcome == .needsYou ? report.question : nil
        symbol = Self.symbol(for: report.kind, outcome: report.outcome)
        answer = report.answer
        userStep = report.outcome == .needsYou ? report.userStep : nil
        routineProposals = report.outcome == .needsYou ? (report.routineProposals ?? []) : []
        if userStep != nil { symbol = "person.crop.circle.badge.clock" }
    }

    /// Follow-up chips: plain text, no list markers or trailing period, at most 80 characters, three at most,
    /// duplicates dropped.
    public static func chips(from steps: [String]) -> [String] {
        var seen = Set<String>()
        var chips: [String] = []
        for step in steps {
            var text = AgentText.stripMarkdown(AgentText.stripCitations(step)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let marker = text.range(of: #"^(?:[-*•]|\d{1,2}[.)])\s+"#, options: .regularExpression) { text.removeSubrange(marker) }
            while text.hasSuffix(".") { text.removeLast() }
            text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.count <= 80, seen.insert(text.lowercased()).inserted else { continue }
            chips.append(text)
            if chips.count == 3 { break }
        }
        return chips
    }

    /// The follow-up a tapped chip sends to the job.
    public static func followUp(for chip: String) -> String { chip }

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(max(1, seconds)) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h \(seconds % 3600 / 60) min"
    }

    static func symbol(for kind: AgentDeliverableKind?, outcome: AgentJobReport.Outcome) -> String {
        switch outcome {
        case .failed: return "exclamationmark.triangle"
        case .stopped: return "stop.circle"
        case .needsYou: return "questionmark.bubble"
        case .done: break
        }
        return switch kind {
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .sheet: "tablecells"
        case .slides: "rectangle.on.rectangle"
        case .image: "photo"
        case .video: "film"
        case .page: "globe"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .message: "text.bubble"
        case .research: "magnifyingglass"
        case nil: "checkmark.seal"
        }
    }
}
