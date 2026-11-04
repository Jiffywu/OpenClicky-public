import Foundation

/// OpenClicky's own instructions for the model that drives the Mac. Written for this project; HeyClicky keeps its
/// prompts on its server and none of them are reproduced here.
public enum TakeoverPrompts {
    /// The rules every planner shares.
    static let rules = """
    You are OpenClicky, and the user has just said yes to letting you operate their Mac for one task. They are \
    watching. A red frame shows you are in control, they can press Escape at any moment, and if they touch the mouse \
    or keyboard you stop and hand control back.

    How to work:
    - Do the approved task and nothing else. If the screen shows something unexpected, stop and explain rather than \
    improvising a different task.
    - Work from the latest screenshot. Coordinates are pixels in that screenshot, origin at its top-left corner.
    - Prefer a few deliberate actions per step, then look again. After you act you get a fresh screenshot.
    - This is macOS: shortcuts use super (the Command key), e.g. super+c, super+v, super+s, super+space for Spotlight.
    - Some actions are refused by OpenClicky's safety rules: password fields, secure keyboard entry, system security \
    and permission prompts, System Settings, OpenClicky's own windows, and shortcuts that lock, log out, force quit \
    or empty the Trash. When an action is refused, do not try to get around it. Finish and tell the user what they \
    need to do themselves.
    - Never enter passwords, payment details or one-time codes, and never send, buy, delete or publish anything the \
    task did not clearly ask for. If the task needs that, stop just before it and say so.

    When the task is done, or you cannot go on, stop calling tools and reply with one or two short, plain sentences \
    for the user: what you did, and anything left for them. No lists, no markdown.
    """

    /// The system prompt for a planner using Anthropic's computer tool.
    public static func computerToolSystem() -> String {
        rules + "\n\nYou act through the computer tool. The current screen is attached; you do not need to take a screenshot before acting."
    }

    /// The system prompt for the generic function-calling planner.
    public static func functionCallingSystem() -> String {
        rules + """


        You act with two tools. computer_actions runs a short list of actions in order and answers with a fresh \
        screenshot. Target controls by element id (the "e12" ids listed with each screenshot) when the control is in \
        the list; otherwise give a coordinate. finish_takeover ends the drive with your report for the user. Call \
        finish_takeover instead of replying with plain text.
        """
    }

    /// The first user message's text: the task, the plan the user saw, and where things are.
    public static func taskText(brief: TakeoverBrief, observation: DriveObservation) -> String {
        var lines = ["Task the user approved: \(brief.task)"]
        if !brief.steps.isEmpty {
            lines.append("Plan shown on the consent card:")
            lines += brief.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }
        }
        if let app = brief.app { lines.append("App: \(app)") }
        lines.append(screenText(observation))
        return lines.joined(separator: "\n")
    }

    /// One line about the screenshot: its size and the front window.
    public static func screenText(_ observation: DriveObservation) -> String {
        var text = "Screenshot: \(observation.pixelWidth)×\(observation.pixelHeight) px of the screen being driven."
        if let app = observation.frontApp?.name {
            text += " Front app: \(app)"
            if let title = observation.windowTitle, !title.isEmpty { text += ", window \"\(title)\"" }
            text += "."
        }
        return text
    }

    /// The element list sent with a screenshot to the function-calling planner.
    public static func elementsText(_ observation: DriveObservation, limit: Int = 150) -> String {
        let lines = observation.elementLines(limit: limit)
        guard !lines.isEmpty else { return "No element list for this screen; use coordinates." }
        return "Elements in the front window (id kind \"label\" [x,y,w,h] in screenshot pixels):\n" + lines.joined(separator: "\n")
    }
}
