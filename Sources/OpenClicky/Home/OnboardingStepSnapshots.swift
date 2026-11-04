import AppKit
import OpenClickyKit
import SwiftUI

/// `OpenClicky --render-onboarding-snapshots <folder>`: the welcome chat (live, typed fallback, finished), the skills
/// picker, the last step, and Settings → Skills after the picks were switched on, from the same fixtures as
/// `--render-snapshots` (no Keychain, permissions, microphone or network).
@MainActor
enum OnboardingStepSnapshots {
    static func run(into folder: URL) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let fixture = try EvidenceSnapshots.Fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try render(fixture, into: folder)
            return 0
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            return 1
        }
    }

    static func render(_ fixture: EvidenceSnapshots.Fixture, into folder: URL) throws {
        func out(_ name: String) -> URL { folder.appendingPathComponent(name + ".png") }
        let services = fixture.services
        let flow = OnboardingModel(services: services)
        flow.playsAudio = false
        func onboarding() -> some View { OnboardingView(flow: flow).environment(services).environment(fixture.model) }
        let size = NSSize(width: 720, height: 520)
        var state = OnboardingState()
        state.furthest = .skills
        func show(_ step: OnboardingStep, _ name: String, dark: Bool = false, _ change: (inout OnboardingState) -> Void = { _ in }) throws {
            state.step = step
            change(&state)
            flow.restore(state)
            try EvidenceSnapshots.render(onboarding(), size: size, dark: dark, to: out("onboarding-\(name)"))
        }

        let opener = OnboardingInterviewScript.opener
        try show(.interview, "interview-preparing") {
            $0.interview = OnboardingInterviewState()
            $0.interview.phase = .preparing
            $0.interview.attempts = 2
        }
        try show(.interview, "interview-live") {
            $0.interview.phase = .live
            $0.interview.lines = [
                .init(role: .assistant, text: opener.joined(separator: " ")),
                .init(role: .user, text: "I'm building a voice assistant app for the Mac in Swift."),
                .init(role: .assistant, text: "A Mac voice assistant, nice. What does a normal day look like: more coding, or more calls and email?"),
            ]
        }
        try show(.interview, "interview-live-dark", dark: true)
        try show(.interview, "interview-typed-fallback") {
            $0.interview = OnboardingInterviewState()
            $0.interview.phase = .scripted
            $0.interview.attempts = 2
            $0.interview.typing = true
            $0.interview.failure = "Always-on voice: no model chosen for the realtime-voice slot."
            $0.interview.lines = opener.map { .init(role: .assistant, text: $0) } + [
                .init(role: .user, text: "Planning a small wedding", typed: true),
                .init(role: .assistant, text: OnboardingInterviewScript.typedQuestions[0]),
            ]
        }
        try show(.interview, "interview-finished") {
            $0.interview.phase = .finished
            $0.interview.saved = true
            $0.interview.lines += [
                .init(role: .user, text: "Spreadsheets in the morning, vendor calls after lunch", typed: true),
                .init(role: .assistant, text: OnboardingInterviewScript.typedQuestions[1]),
                .init(role: .user, text: "Chasing vendor emails", typed: true),
                .init(role: .assistant, text: OnboardingInterviewScript.typedQuestions[2]),
                .init(role: .user, text: "Only ChatGPT so far", typed: true),
                .init(role: .assistant, text: OnboardingInterviewScript.typedWrapUp),
            ]
        }

        // The picker with the first-launch defaults, then one more pick.
        let picker = SkillPicker(stateURL: fixture.root.appendingPathComponent("skill-picks.json"))
        try show(.skills, "skills-picker") { $0.skillPicks = picker.loadPicks() }
        try show(.skills, "skills-picker-dark", dark: true) { $0.skillPicks = (picker.loadPicks()) + ["meetings"] }

        // Leaving the step switches the picks on; the last step and Settings → Skills show it.
        let picks = state.skillPicks ?? []
        let result = picker.activate(picks, library: services.skills.library)
        services.skills.reload()
        state.furthest = .done
        try show(.done, "done-with-chat-and-skills") {
            $0.firstQuestion = "What can you help me with?"
            $0.completedAt = Date()
            $0.skillsNote = result.summary
        }
        services.settingsPage = .skills
        let settings = SettingsView().environment(services).environment(fixture.model)
        try EvidenceSnapshots.render(settings, size: NSSize(width: 860, height: 620), to: out("settings-skills-after-picker"))
        print("picker: \(picks.joined(separator: ", ")) → \(result.summary) active: \(services.skills.library.activeSkills().map(\.id).joined(separator: ", "))")
    }
}
