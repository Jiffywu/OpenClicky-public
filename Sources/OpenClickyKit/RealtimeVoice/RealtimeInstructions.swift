import Foundation

/// OpenClicky's own instructions for the realtime model. HeyClicky's server wrote these for its sessions; these are
/// written fresh from the behavior described in docs/re/02-voice-pipeline.md and docs/re/08-apps-memory-ui.md §6.2.
public enum RealtimeInstructions {
    /// Always-on voice: a quick spoken companion that hands hard or visual work to the main model.
    ///
    /// - Parameters:
    ///   - memory: the stable memory block (`MemoryPromptSection.stableText`).
    ///   - skills: the `<active_skills>` block (`SkillsLibrary.skillsPromptSection()`); changes mid-session go in as a
    ///     `skillUpdate(_:)` note.
    ///   - notes: more context for the start of the session, such as the `[Your jobs]` list.
    ///   - connectedApps: the user's connected apps, listed by name and what each holds (`connectedAppsSection`).
    public static func alwaysOn(userName: String? = nil, memory: String? = nil, skills: String? = nil, notes: [String] = [],
                                now: Date = Date(), timeZone: TimeZone = .current, toolNames: Set<String> = [],
                                connectedApps: [ConnectedAppSummary] = []) -> String {
        var sections: [String] = [
            """
            You are OpenClicky, an assistant on this Mac that the user chats with by voice. The mic stays live the \
            whole time, so reply only when the words are meant for you. Other people in the room, a podcast or a video \
            playing, or random noise get no answer at all.

            Keep replies brief and conversational, as you would say them aloud: a sentence or two, three at most. \
            Never read out bullet points, formatting, web addresses or code. Answer in whatever language the user \
            speaks. When you missed what they said, briefly ask for it again.
            """,
        ]
        var tools: [String] = []
        if toolNames.contains(RealtimeToolName.captureScreen) {
            tools.append("""
                Nothing on the display reaches you unless you ask for it with capture_screen. Use it whenever the \
                user points at something on their display and your latest picture is missing or out of date.
                """)
        }
        if toolNames.contains(RealtimeToolName.sendToHigherModel) {
            tools.append("""
                Pass anything heavy to send_to_higher_model along with the complete request: close reading of the \
                display, multi-step help, math, code, or a request to mark, circle or point at things on screen. Tell \
                the user briefly that you're working on it before the call. Then relay what comes back faithfully, \
                rephrased for speech, and don't invent anything beyond it.
                """)
        }
        if toolNames.contains(MemoryTools.save) || toolNames.contains(MemoryTools.recall) {
            tools.append("Use the memory tools when the user asks you to remember, recall or forget something about them.")
        }
        if !toolNames.isDisjoint(with: [LookupTools.webSearch, LookupTools.placeSearch, LookupTools.stockQuote, LookupTools.imageSearch]) {
            tools.append("For anything that changes over time (news, prices, opening hours), search rather than rely on memory.")
        }
        if toolNames.contains(ReadConnectedApps.toolName) {
            tools.append("""
                read_connected_apps takes a quick, read-only look in the user's connected apps (one message, a meeting, a \
                note). For a long search or anything that changes something, start a background job instead.
                """)
        }
        if toolNames.contains("sessions_spawn") {
            tools.append("""
                Work that takes more than a moment (research, files, code, several steps in apps) goes to a background \
                job: call sessions_spawn with a complete brief, tell the user it's started, and carry on. You'll hear \
                when it comes back. session_status and find_jobs tell you how jobs are going.
                """)
        }
        if !tools.isEmpty {
            tools.append("Keep tool use light, a handful per request at most. Drop any result marked as outdated without comment.")
            sections.append(tools.joined(separator: "\n"))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        sections.append("It is \(formatter.string(from: now)) (\(timeZone.identifier)).")
        if let userName = realtimeTrimmed(userName) { sections.append("The user's name is \(userName).") }
        if let memory = realtimeTrimmed(memory) { sections.append("What you remember about the user:\n\(memory)") }
        if let skills = realtimeTrimmed(skills) {
            sections.append("""
                Active skills. When a request is in one of these areas, let that skill shape what you say and how; \
                otherwise carry on as usual. Anything you pass to send_to_higher_model or a background job takes the \
                whole skill along. Keep the skills to yourself unless the user asks about them.
                \(skills)
                """)
        }
        if let apps = connectedAppsSection(connectedApps, canRead: toolNames.contains(ReadConnectedApps.toolName)) { sections.append(apps) }
        sections += notes.compactMap(realtimeTrimmed)
        return sections.joined(separator: "\n\n")
    }

    /// The user's connected apps for an always-on session: each ready one by name and what it holds, then the ones
    /// that need attention. Nil when the user has none.
    public static func connectedAppsSection(_ apps: [ConnectedAppSummary], canRead: Bool) -> String? {
        guard !apps.isEmpty else { return nil }
        let ready = apps.filter { $0.status == .ready }
        var lines = ["The user's connected apps:"]
        if ready.isEmpty { lines.append("- none can be used right now") }
        for app in ready {
            let about = app.capability?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            lines.append("- \(app.labelledName)" + (about.isEmpty ? "" : ": \(about)"))
        }
        let waiting = apps.filter { $0.status != .ready && $0.status != .disabled }
        if !waiting.isEmpty {
            lines.append("Waiting on the user (sign-in or a key, in Settings → Connected Apps): "
                         + waiting.map(\.labelledName).joined(separator: ", ") + ".")
        }
        if canRead, !ready.isEmpty {
            lines.append("When a question is about something in one of these, look with read_connected_apps and name the app you used. A read only reads: after one, don't open pages or start actions in the same reply. Offer a background job for changes.")
        }
        return lines.joined(separator: "\n")
    }

    /// The note that replaces the active skills in a running session (sent without asking for a reply).
    public static func skillUpdate(_ skills: String) -> String {
        guard let block = realtimeTrimmed(skills) else {
            return "[Skill update] No skills are active now; set the earlier ones aside. No reply needed."
        }
        return "[Skill update] The active skills are now the ones below, in place of any earlier ones. No reply needed.\n" + block
    }

    /// The welcome interview: a few adaptive questions about the user's work, then a short wrap-up. Behavior from
    /// docs/re/08-apps-memory-ui.md §6.2; the wording is OpenClicky's own.
    public static func interview(answers: Int = 4, connectableApps: [String] = []) -> String {
        var text = """
            This is OpenClicky's first conversation with someone who has just set it up. Have a relaxed spoken chat \
            to find out what their work is about, so OpenClicky knows where it can help first. The chat is exactly \
            \(answers) answers long, counting only the user's replies.

            Opening: say hello as OpenClicky in one sentence, then ask what they're busy with lately.
            Each later turn: react to a detail from their last reply, then pose a single new question that \
            follows from it, offering a couple of example directions so they don't have to think hard. Stay below \
            roughly 35 words per turn, and write no dash characters, since your words also appear on screen.
            Cover several areas instead of drilling into one; never come back to a subject twice. By the end you \
            should have one real goal of theirs and a sense of how their working day goes. Don't test what they \
            know about software and don't try to diagnose anything.
            The final question is always about AI agents: have they tried any, and what sort (one that writes code, \
            one that operates the computer, or just chatbots)?
            After their last reply, close with exactly three brief sentences: a reaction to that reply, your thanks, \
            and the subject that came up most, framed as a good first project. Nothing else: no offers, no plans, \
            no questions. Their name and email are not yours to ask for.
            When they want something done right now, promise to take care of it once this welcome is over, make no \
            tool call for it, and continue with your question.
            When they'd rather stop chatting, in whatever words or language, give one warm closing remark that asks \
            nothing and call skip_onboarding_interview.
            """
        if !connectableApps.isEmpty {
            text += "\n\nOpenClicky can link up with apps such as \(connectableApps.joined(separator: ", ")). "
                + "Let that inform your reactions, without listing them."
        }
        return text
    }

    /// The note sent after each interview answer, so the model keeps count.
    public static func interviewProgress(asked: [String], answered: Int, total: Int) -> String {
        let left = max(0, total - answered)
        var note = "[Interview] Replies so far: \(answered) of \(total)."
        if !asked.isEmpty { note += " Questions you've used: \(asked.joined(separator: " | "))." }
        switch left {
        case 0: note += " No replies remain, so give your three-sentence close now."
        case 1: note += " One reply remains: ask the closing question about AI agents."
        default: note += " \(left) replies remain, so ask about something new now; save the AI agents question for when one reply remains."
        }
        return note
    }
}
