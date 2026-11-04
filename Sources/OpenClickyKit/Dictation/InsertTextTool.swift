import Foundation

/// `insert_text`: the brain types text where the user's cursor is, through dictation's `TextInserter` (the same
/// strategies, secure-field refusal and clipboard fallback). It changes what is on screen, so it waits until the
/// narration (or the always-on voice's reply) has been spoken. HeyClicky's higher model does this with `[TYPE:…]`
/// markers; the outcome comes back to always-on voice as `text_typed` or `delivery_refused`.
public enum InsertTextTool {
    public static let name = "insert_text"
    static let maxCharacters = 20_000

    public static let spec = ToolSpec(
        name: name,
        description: """
            Type text into the field where the user's text cursor is (an email body, a search box, a chat message), as \
            if they had typed it. Use it only when they ask you to write or fill something in for them. It runs right \
            after your spoken reply. Password fields and secure input refuse it. Result status: queued now; afterwards \
            completed (typed), copied (left on the clipboard when no field took it) or refused.
            """,
        parameters: [
            "type": "object",
            "properties": [
                "text": ["type": "string", "description": "The exact text to type."],
            ],
            "required": ["text"],
            "additionalProperties": false,
        ])

    /// The tool on `inserter` (the app passes `TextInserter(system: SystemTextInsertion())`).
    public static func make(inserter: TextInserter) -> AppTool {
        AppTool.make(
            spec: spec, needsFollowUpRound: false, defersUntilNarrationEnds: true, isReadOnly: false,
            statusLabel: "Typing…",
            parse: { arguments in
                guard let text = try arguments.rawString("text", maxLength: maxCharacters),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ToolArgumentError("Missing \"text\" to type.")
                }
                return text
            },
            perform: { text in result(of: await inserter.insert(text, into: nil)) })
    }

    /// What the model reads after the typing ran.
    static func result(of report: InsertionReport) -> AppToolResult {
        let characters: JSONValue = .number(Double(report.insertedText.count))
        switch report.outcome {
        case .inserted(let strategy):
            return AppToolResult(.completed, "Typed into \(report.appName ?? "the focused field").",
                                 details: ["typed": true, "strategy": .string(strategy.rawValue), "characters": characters])
        case .copiedToClipboard(let failure):
            return AppToolResult(.copied, "No field took the text (\(failure.rawValue)), so it is on the clipboard to paste.",
                                 details: ["typed": false, "characters": characters])
        case .refused(let refusal):
            return AppToolResult(.refused, "Typing was refused (\(refusal.rawValue)).\(report.copiedToClipboard ? " The text is on the clipboard." : "")",
                                 details: ["typed": false, "refusal": .string(refusal.rawValue)])
        case .nothingToInsert:
            return AppToolResult(.invalidRequest, "There was no text to type.")
        }
    }

    /// Whether typing into the focused field would be refused right now (a password field, or Secure Event Input).
    public static func wouldRefuse(system: any TextInsertionSystem) -> Bool {
        if system.isSecureEventInputEnabled() { return true }
        return system.currentFocus()?.context.isSecure == true
    }
}

extension AppToolbox {
    /// This toolbox plus `tool` (a tool with the same name already there is kept as it is).
    public func adding(_ tool: AppTool) -> AppToolbox {
        guard self[tool.name] == nil else { return self }
        return AppToolbox(tools + [tool])
    }
}
