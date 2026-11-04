import OpenClickyKit
import SwiftUI

/// The first-run flow: what OpenClicky is, permissions with live status, models and keys, a test line, the talk
/// keys, and a first question.
struct OnboardingView: View {
    let flow: OnboardingModel

    var body: some View {
        HStack(spacing: 0) {
            StepList(flow: flow)
                .frame(width: 190)
                .background(Color.secondary.opacity(0.06))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    Group {
                        switch flow.machine.step {
                        case .welcome: WelcomeStep()
                        case .permissions: PermissionsStep(flow: flow)
                        case .providers: ProvidersStep(flow: flow)
                        case .voiceTest: VoiceTestStep(flow: flow)
                        case .talkKeys: TalkKeysStep(flow: flow)
                        case .interview: InterviewStep(flow: flow)
                        case .skills: SkillsPickerStep(flow: flow)
                        case .firstQuestion: FirstQuestionStep(flow: flow)
                        case .done: DoneStep(flow: flow)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(28)
                }
                Divider()
                Footer(flow: flow)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: 720, height: 520)
    }
}

private struct StepList: View {
    let flow: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
                .padding(.bottom, 10)
            ForEach(OnboardingStep.allCases.filter { $0 != .done }, id: \.self) { step in
                let current = flow.machine.step == step
                let reached = step <= flow.state.furthest
                Button {
                    flow.send(.goTo(step))
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: step < flow.machine.step || flow.machine.isComplete ? "checkmark.circle.fill" : current ? "circle.inset.filled" : "circle")
                            .foregroundStyle(step < flow.machine.step || flow.machine.isComplete ? Color.green : current ? Color.accentColor : Color.secondary)
                        Text(step.title)
                            .fontWeight(current ? .semibold : .regular)
                            .foregroundStyle(reached ? Color.primary : Color.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!reached)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 36)
    }
}

private struct Footer: View {
    let flow: OnboardingModel

    var body: some View {
        HStack {
            if flow.machine.step != .welcome && flow.machine.step != .done {
                Button("Back") { flow.send(.back) }
            }
            Spacer()
            if let blocker = flow.machine.blocker {
                Text(blocker)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            switch flow.machine.step {
            case .permissions where !flow.machine.canContinue:
                Button("Continue Without") { flow.send(.continueWithoutPermissions) }
            case .voiceTest where !flow.machine.canContinue:
                Button("Skip") { flow.send(.skipVoiceTest) }
            case .firstQuestion:
                Button("Finish Without Asking") { flow.send(.next) }
            case .interview where !flow.state.interview.isOver:
                Button("Skip") { flow.send(.skipInterview) }
            default:
                EmptyView()
            }
            if flow.machine.step == .done {
                Button("Close") { flow.send(.dismiss) }.keyboardShortcut(.defaultAction)
            } else if flow.machine.step == .interview && !flow.state.interview.isOver {
                EmptyView()
            } else if flow.machine.step != .firstQuestion {
                Button(flow.machine.step == .welcome ? "Get Started" : "Continue") { flow.send(.next) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!flow.machine.canContinue)
            }
        }
    }
}

private struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title.weight(.semibold))
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 14)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(title: "Meet OpenClicky",
                       subtitle: "A helper that lives in your menu bar. Hold two keys, ask out loud, and it looks at your screen, answers in a voice, and points or draws right where you're working.")
            Feature(symbol: "mic.fill", title: "Ask out loud", text: "Hold your talk keys and speak. Let go and it answers.")
            Feature(symbol: "rectangle.dashed.and.paperclip", title: "It sees what you see", text: "It looks at your screen only when you ask, so it can talk about the thing in front of you.")
            Feature(symbol: "scribble.variable", title: "Points and draws", text: "It can point at the button you need or sketch a diagram over your screen while it explains.")
            Feature(symbol: "sparkles.rectangle.stack", title: "Works in the background", text: "Bigger jobs, like research or a spreadsheet, go to an agent that reports back when it's done.")
            Feature(symbol: "key.fill", title: "Your models, your keys", text: "You choose which AI services it uses. Keys stay in your Mac's Keychain.")
        }
    }
}

private struct Feature: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionsStep: View {
    let flow: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: "Let OpenClicky hear, see and point",
                       subtitle: "macOS asks you to allow each of these once. The list updates as soon as you flip a switch in System Settings.")
            ForEach(OnboardingPermission.allCases, id: \.self) { permission in
                let granted = flow.state.permissions[permission] == true
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: granted ? "checkmark.circle.fill" : permission.isRequired ? "circle.dashed" : "circle")
                        .font(.title3)
                        .foregroundStyle(granted ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(OnboardingModel.map(permission)?.title ?? permission.rawValue).font(.headline)
                            + Text(permission.isRequired ? "" : "  optional").font(.caption).foregroundColor(.secondary)
                        Text(OnboardingModel.map(permission)?.why ?? "").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if granted {
                        Text("Allowed").foregroundStyle(.green)
                    } else if let mapped = OnboardingModel.map(permission), flow.permissionState(permission) == .restartRequired {
                        // Allowed in System Settings, but only a fresh launch can use it (Screen Recording).
                        VStack(alignment: .trailing, spacing: 2) {
                            Button("Quit & Reopen") { flow.model.permissions.quitAndReopen() }.buttonStyle(.borderedProminent)
                            Text("Allowed; needs a restart").font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("\(mapped.title) needs OpenClicky to quit and reopen")
                    } else if let mapped = OnboardingModel.map(permission), flow.permissionState(permission) == .denied {
                        VStack(alignment: .trailing, spacing: 2) {
                            Button("Open System Settings") { NSWorkspace.shared.open(mapped.settingsURL) }
                            Text("Turned off").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Allow…") { flow.send(.requestPermission(permission)) }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(0.07)))
            }
        }
    }
}

private struct ProvidersStep: View {
    let flow: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: "Choose your models",
                       subtitle: "Pick a starting setup; you can change any part later in Settings → Models. Paste the keys it needs; they're saved in your Keychain.")
            ForEach(OnboardingSetupPlan.all) { plan in
                let applied = plan.isApplied(in: flow.model.config)
                Button {
                    flow.choose(plan)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: applied ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(applied ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plan.title).font(.headline)
                            Text(plan.detail).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(applied ? Color.accentColor : Color.secondary.opacity(0.25)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !flow.neededKeys.isEmpty {
                Text("Keys").font(.headline).padding(.top, 6)
                ForEach(flow.neededKeys, id: \.name) { needed in
                    KeyRow(flow: flow, name: needed.name, preset: needed.preset)
                }
            }
            if let message = flow.keyMessage {
                Label(message, systemImage: "checkmark.seal").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(flow.state.providerProblems, id: \.self) { problem in
                Label(problem, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(.red)
            }
            ForEach(flow.state.providerWarnings.prefix(3), id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

private struct KeyRow: View {
    let flow: OnboardingModel
    let name: String
    let preset: ProviderPreset?

    var body: some View {
        let stored = flow.storedKeys.contains(name)
        HStack(spacing: 8) {
            Image(systemName: stored ? "checkmark.circle.fill" : "key")
                .foregroundStyle(stored ? Color.green : Color.secondary)
                .frame(width: 18)
            Text(preset?.name ?? name).frame(width: 110, alignment: .leading)
            SecureField(stored ? "Stored in Keychain" : "Paste your \(preset?.name ?? name) key", text: Binding(
                get: { flow.keyDrafts[name] ?? "" }, set: { flow.keyDrafts[name] = $0 }))
                .onSubmit { flow.saveKey(name) }
            Button(stored ? "Replace" : "Save") { flow.saveKey(name) }
                .disabled((flow.keyDrafts[name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            if let url = preset?.keyHelpURL {
                Link("Get a key", destination: url).font(.caption)
            }
        }
    }
}

private struct VoiceTestStep: View {
    let flow: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(title: "Hear your voice",
                       subtitle: "OpenClicky will say one line through the voice you picked. Turn your sound up if you can.")
            let voice = flow.model.config.slots[.voice]
            Label("\(voice?.provider ?? "no provider") · \(voice?.model ?? "no model")\(voice?.voice.map { " · \($0)" } ?? "")", systemImage: "waveform")
                .font(.callout)
            Text("“\(OnboardingMachine.testLine)”")
                .italic()
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    flow.send(.startVoiceTest)
                } label: {
                    Label(flow.state.voiceTest == .speaking ? "Speaking…" : "Play Test Line", systemImage: "play.circle.fill")
                }
                .controlSize(.large)
                .disabled(flow.state.voiceTest == .speaking)
                switch flow.state.voiceTest {
                case .succeeded(let seconds):
                    Label(String(format: "Spoke %.1f seconds of audio.", seconds), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(3)
                case .speaking:
                    ProgressView().controlSize(.small)
                case .notTried:
                    EmptyView()
                }
            }
        }
    }
}

private struct TalkKeysStep: View {
    let flow: OnboardingModel
    @Environment(HomeServices.self) private var services

    var body: some View {
        let keys = services.talkKeys.settings
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(title: "Your talk keys",
                       subtitle: "These work in any app. You can change them in Settings → Talk keys.")
            KeyCard(symbol: keys.voice.symbol, title: keys.voice.phrase, text: keys.voice.kind == .hold ? "Talk to OpenClicky. Let go when you're done; it answers out loud."
                    : "Talk to OpenClicky. Tap the key once more when you're done; it answers out loud.")
            KeyCard(symbol: keys.text.symbol, title: keys.text.phrase, text: "Type a question instead of saying it.")
            KeyCard(symbol: keys.dictation.symbol, title: keys.dictation.phrase, text: "Dictate into whatever text field you're in.")
            HStack(spacing: 8) {
                Image(systemName: flow.state.practicedTalkKey ? "checkmark.circle.fill" : "hand.point.right")
                    .foregroundStyle(flow.state.practicedTalkKey ? Color.green : Color.accentColor)
                Text(flow.state.practicedTalkKey ? "Nice, that's it." : "Try it now: \(keys.voice.phrase.lowercased()) for a moment.")
            }
            .font(.callout)
        }
        .onAppear { flow.watchTalkKeys(keys.voice) }
        .onDisappear { flow.stopWatchingTalkKeys() }
    }
}

private struct KeyCard: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            Text(symbol)
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .frame(minWidth: 70)
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct FirstQuestionStep: View {
    let flow: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: "Ask your first question",
                       subtitle: "Pick one or write your own. The answer opens in Home; next time, try asking out loud.")
            ForEach(OnboardingModel.suggestedQuestions, id: \.self) { question in
                Button {
                    flow.send(.askFirstQuestion(question))
                } label: {
                    HStack {
                        Image(systemName: "text.bubble")
                        Text(question)
                        Spacer()
                        Image(systemName: "arrow.right.circle")
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(0.08)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                TextField("Or type a question…", text: Binding(get: { flow.firstQuestion }, set: { flow.firstQuestion = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { flow.send(.askFirstQuestion(flow.firstQuestion)) }
                Button("Ask") { flow.send(.askFirstQuestion(flow.firstQuestion)) }
                    .disabled(flow.firstQuestion.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

private struct DoneStep: View {
    let flow: OnboardingModel
    @Environment(HomeServices.self) private var services

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: "You're all set",
                       subtitle: "OpenClicky is in your menu bar. \(services.talkKeys.settings.voice.phrase) whenever you want help.")
            if let question = flow.state.firstQuestion {
                Label("Asked: \(question)", systemImage: "text.bubble")
            }
            if flow.state.interview.saved {
                Label("Saved \(flow.state.interview.answers.count) answers from the welcome chat to your memory.", systemImage: "person.text.rectangle")
            }
            if let note = flow.state.skillsNote {
                Label(note, systemImage: "sparkles")
            }
            Button("Open Home") { services.openHome(section: .chat) }
        }
    }
}

/// The welcome chat: a few spoken questions in the realtime voice (or typed), shown as bubbles. Answers go to memory.
private struct InterviewStep: View {
    let flow: OnboardingModel

    var body: some View {
        let interview = flow.state.interview
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: "A quick chat",
                       subtitle: "OpenClicky asks \(interview.total) short questions out loud so it knows where to help first. Answer by talking, or type instead. Your answers stay in its memory on this Mac.")
            HStack(spacing: 8) {
                switch interview.phase {
                case .notStarted, .preparing:
                    ProgressView().controlSize(.small)
                    Text(interview.attempts > 1 ? "Trying the voice chat again…" : "Getting the voice chat ready…")
                case .live:
                    Image(systemName: "waveform").foregroundStyle(.tint)
                    Text("Listening. Just talk; OpenClicky waits for you to finish.")
                case .scripted:
                    Image(systemName: "keyboard").foregroundStyle(.orange)
                    Text("The voice chat isn't available, so type your answers.")
                case .finished:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Thanks! Saved to memory.")
                case .skipped:
                    Image(systemName: "forward.end.fill").foregroundStyle(.secondary)
                    Text(interview.answers.isEmpty ? "Skipped." : "Skipped. Your \(interview.answers.count) answer\(interview.answers.count == 1 ? " is" : "s are") saved to memory.")
                }
                Spacer()
                if !interview.isOver, interview.phase != .preparing {
                    Text("Answer \(min(interview.answers.count + 1, interview.total)) of \(interview.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            if let failure = interview.failure, interview.phase == .scripted {
                Text(failure).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(interview.lines.enumerated()), id: \.offset) { _, line in
                    InterviewBubble(line: line)
                }
            }
            if interview.phase == .live || interview.phase == .scripted {
                if interview.typing || interview.phase == .scripted {
                    HStack {
                        TextField("Type your answer…", text: Binding(get: { flow.interviewDraft }, set: { flow.interviewDraft = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { flow.sendTypedAnswer() }
                        Button("Send") { flow.sendTypedAnswer() }
                            .disabled(flow.interviewDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    Button("Or type here") { flow.send(.interviewTyping(true)) }.buttonStyle(.link)
                }
            }
            if interview.isOver {
                Button("Start Over") { flow.send(.startInterview) }
            }
        }
    }
}

private struct InterviewBubble: View {
    let line: OnboardingInterviewLine

    var body: some View {
        let mine = line.role == .user
        HStack {
            if mine { Spacer(minLength: 60) }
            HStack(alignment: .top, spacing: 6) {
                if !mine { Image(systemName: "cursorarrow.rays").foregroundStyle(.tint) }
                Text(line.text).fixedSize(horizontal: false, vertical: true)
                if line.typed == true { Image(systemName: "keyboard").font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(mine ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1)))
            if !mine { Spacer(minLength: 60) }
        }
    }
}

/// "What should it be good at?": OpenClicky's starter skills by category; one card can switch on several skills.
private struct SkillsPickerStep: View {
    let flow: OnboardingModel

    var body: some View {
        let picks = Set(flow.state.skillPicks ?? [])
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: "What should it be good at?",
                       subtitle: "Pick what you'd like help with. Each choice switches on a skill or two that shape how OpenClicky and its background agents work. Change them any time in Settings → Skills.")
            // Every entry in one grid, in the catalog's category order, each card captioned with its category.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(flow.skillPicker.categories()) { group in
                    ForEach(group.entries) { entry in
                        SkillPickCard(entry: entry, category: group.category, picked: picks.contains(entry.id)) {
                            flow.send(.toggleSkillPick(entry.id))
                        }
                    }
                }
            }
        }
    }
}

private struct SkillPickCard: View {
    let entry: SkillPickerEntry
    let category: SkillCategory
    let picked: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: entry.symbol)
                    .frame(width: 20)
                    .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.name.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(Color(hex: category.color))
                    Text(entry.title).font(.callout.weight(.semibold))
                    Text(entry.subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if entry.skillIDs.count > 1 {
                        Text("\(entry.skillIDs.count) skills").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(picked ? Color.accentColor : Color.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(picked ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(picked ? Color.accentColor : Color.secondary.opacity(0.2)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
