import Foundation

/// The brain's take-over tools: offer_screen_takeover, start_screen_takeover and end_screen_takeover.
///
/// They are `AppTool`s; the brain runtime registers them with `ToolRegistry.takeoverTools(_:)` (group `.takeover`,
/// which also adds their rule to the prompt). Results use the app-tool status words: `needs_confirmation` for an
/// offer waiting on the user, `ok` for a drive that started or stopped, `refused` when the user has not said yes.
/// None of the tools can grant consent; only the user can (`TakeoverController.approve`).
public struct TakeoverTools: Sendable {
    public let controller: TakeoverController

    public init(controller: TakeoverController) {
        self.controller = controller
    }

    public static let offerName = "offer_screen_takeover"
    public static let startName = "start_screen_takeover"
    public static let endName = "end_screen_takeover"
    public static let names: Set<String> = [offerName, startName, endName]

    public static let offerSpec = ToolSpec(
        name: offerName,
        description: """
        Ask the user whether you may operate their Mac (move the pointer, click and type) to do a task for them. \
        Use it when doing the task yourself is clearly easier for the user than following directions, and only for \
        tasks in their apps that need no passwords, payments or system settings. A card shows the task and plan; \
        ask out loud in the same turn, in a few words, and wait for their answer. Never call start_screen_takeover \
        in the same turn as the offer.
        """,
        parameters: [
            "type": "object",
            "properties": [
                "task": ["type": "string", "description": "What you will do, in plain words the user will see on the card."],
                "steps": ["type": "array", "items": ["type": "string"], "maxItems": 8,
                          "description": "Up to 8 short steps you plan to take."],
                "app": ["type": "string", "description": "The app the task happens in."],
            ],
            "required": ["task"],
            "additionalProperties": false,
        ])

    public static let startSpec = ToolSpec(
        name: startName,
        description: """
        Start the take-over the user just agreed to (they said yes after your offer, or clicked the card). It drives \
        the task shown on the card, not a new one; you hear how it went when it ends. Fails if the user has not said yes.
        """,
        parameters: ["type": "object", "properties": [:], "additionalProperties": false])

    public static let endSpec = ToolSpec(
        name: endName,
        description: "Stop a take-over that is running, or withdraw an offer the user has not answered.",
        parameters: [
            "type": "object",
            "properties": ["reason": ["type": "string", "description": "Why, in a few words."]],
            "additionalProperties": false,
        ])

    public static var specs: [ToolSpec] { [offerSpec, startSpec, endSpec] }

    /// The three tools as app tools. They run at once (the card and the drive are their own UI, so nothing waits
    /// for the narration) and need no follow-up round.
    public var appTools: [AppTool] {
        let controller = controller
        return [
            AppTool.make(spec: Self.offerSpec, needsFollowUpRound: false, defersUntilNarrationEnds: false, isReadOnly: false,
                         statusLabel: "Asking to drive…", parse: Self.parseOffer,
                         perform: { brief in await Self.offer(brief, controller: controller) }),
            AppTool.make(spec: Self.startSpec, needsFollowUpRound: false, defersUntilNarrationEnds: false, isReadOnly: false,
                         statusLabel: "Taking over…", parse: { _ in () },
                         perform: { _ in await Self.start(controller: controller) }),
            AppTool.make(spec: Self.endSpec, needsFollowUpRound: false, defersUntilNarrationEnds: false, isReadOnly: false,
                         statusLabel: "Stopping…", parse: { try $0.string("reason", maxLength: 300) },
                         perform: { _ in await Self.end(controller: controller) }),
        ]
    }

    /// A toolbox holding just these three (merge `appTools` into the brain's toolbox instead when there is one).
    public var toolbox: AppToolbox { AppToolbox(appTools) }

    /// Runs a call by name with JSON argument text.
    public func run(_ call: ToolCall) async -> AppToolResult {
        await toolbox.run(call)
    }

    // MARK: - Handlers

    static func parseOffer(_ arguments: ToolArguments) throws -> TakeoverBrief {
        let task = try arguments.requiredString("task", maxLength: 500)
        var steps: [String] = []
        if let raw = arguments.values["steps"], raw != .null {
            guard let items = raw.arrayValue, items.allSatisfy({ $0.stringValue != nil }) else {
                throw ToolArgumentError("\"steps\" must be an array of strings.")
            }
            guard items.count <= 8 else { throw ToolArgumentError("\"steps\" holds at most 8 items.") }
            steps = items.compactMap(\.stringValue).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)) }
                .filter { !$0.isEmpty }
        }
        let app = try arguments.string("app", maxLength: 120)
        return TakeoverBrief(task: task, steps: steps, app: app)
    }

    static func offer(_ brief: TakeoverBrief, controller: TakeoverController) async -> AppToolResult {
        do {
            let offer = try await controller.offer(brief)
            return AppToolResult(.needsConfirmation,
                                 "The card asking to drive is showing. Ask the user out loud too, then wait for their answer; call start_screen_takeover only after they say yes.",
                                 details: ["takeover": "offered", "offer_id": .string(offer.id)])
        } catch TakeoverConsentError.alreadyDriving {
            return AppToolResult(.refused, "A take-over is already running. End it first with end_screen_takeover.")
        } catch {
            return AppToolResult(.invalidRequest, String(describing: error))
        }
    }

    static func start(controller: TakeoverController) async -> AppToolResult {
        switch controller.phase {
        case .idle:
            return AppToolResult(.refused, "No take-over has been approved. Call offer_screen_takeover, then wait until the user agrees.",
                                 details: ["takeover": "idle"])
        case .offered:
            return AppToolResult(.refused, "The user has not said yes yet. Wait for their answer; don't start without it.",
                                 details: ["takeover": "offered"])
        case .driving, .stopping:
            return AppToolResult(.ok, "The take-over is already running.", details: ["takeover": "driving"])
        case .approved:
            do {
                let offer = try await controller.start()
                return AppToolResult(.ok, "Driving now. You'll hear how it went when it ends; the user can press Escape to stop it.",
                                     details: ["takeover": "driving", "task": .string(offer.brief.task)])
            } catch let error as TakeoverConsentError {
                return AppToolResult(.refused, error.description)
            } catch {
                return AppToolResult(.failed, "The take-over could not start: \(error)")
            }
        }
    }

    static func end(controller: TakeoverController) async -> AppToolResult {
        let before = controller.phase
        guard await controller.stop(.endedByBrain) else {
            return AppToolResult(.notFound, "Nothing to end: no take-over is offered or running.")
        }
        return before.isDriving
            ? AppToolResult(.ok, "Stopping the take-over.", details: ["takeover": "stopping"])
            : AppToolResult(.ok, "Withdrew the offer.", details: ["takeover": "withdrawn"])
    }
}
