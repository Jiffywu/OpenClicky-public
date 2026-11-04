import AppKit
import OpenClickyKit
import SwiftUI

/// One display's notch panel: the surface the presenter picked, hanging from the top centre at the exact size
/// `NotchGeometry.contentSize(for:)` gives (so the manager's hit-testing matches what is drawn).
struct NotchRootView: View {
    let display: UInt32
    let controller: NotchController
    @Environment(NotchModel.self) private var notch

    var body: some View {
        let geometry = notch.geometries[display] ?? NotchGeometry(screenFrame: CGRect(origin: .zero, size: NotchGeometry.envelope), notchRect: nil)
        let surface = notch.surface(on: display)
        let size = geometry.contentSize(for: surface)
        ZStack(alignment: .top) {
            content(surface, geometry: geometry)
                .frame(width: size.width, height: size.height, alignment: .top)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                .id(surfaceKey(surface))
        }
        .frame(width: NotchGeometry.envelope.width, height: NotchGeometry.envelope.height, alignment: .top)
        // Always black, so always dark controls (the panel's appearance says the same to AppKit).
        .environment(\.colorScheme, .dark)
        .animation(.spring(duration: 0.28, bounce: 0.15), value: surfaceKey(surface))
        .animation(.easeOut(duration: 0.12), value: notch.dwell)
    }

    @ViewBuilder
    private func content(_ surface: NotchSurface, geometry: NotchGeometry) -> some View {
        switch surface {
        case .hidden:
            Color.clear
        case .tucked:
            NotchTuckedView(geometry: geometry, dwell: notch.dwell) { controller.model.send(.clickNotch(display: display)) }
        case .activity:
            NotchActivityView(geometry: geometry, stopTarget: notch.stopTarget, stop: { controller.model.send(.stop) }) {
                controller.model.send(.clickNotch(display: display))
            }
        case .liveEvent(let event):
            NotchLiveEventCard(event: event, geometry: geometry, now: notch.clock, progress: notch.eventProgress,
                               send: { controller.model.send($0) })
        case .onboarding:
            NotchOnboardingCard(geometry: geometry, continueSetup: controller.openOnboarding, later: controller.deferOnboarding)
        case .open(let tab):
            NotchOpenPanel(tab: tab, geometry: geometry, controller: controller)
        }
    }

    /// Changes only when the kind of surface changes, so a ticking countdown doesn't replay the transition.
    private func surfaceKey(_ surface: NotchSurface) -> String {
        switch surface {
        case .liveEvent(let event): "event:\(event.id)"
        default: surface.name
        }
    }
}

// MARK: - Shapes and colours

/// Black, squared at the top (it continues the camera housing), rounded at the bottom.
struct NotchShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous).path(in: rect)
    }
}

extension NotchTone {
    var color: Color {
        switch self {
        case .info: Color(red: 0.42, green: 0.66, blue: 1)
        case .success: Color(red: 0.36, green: 0.84, blue: 0.52)
        case .attention: Color(red: 1, green: 0.74, blue: 0.28)
        case .warning: Color(red: 1, green: 0.5, blue: 0.38)
        }
    }
}

// MARK: - Folded

/// The bare notch: invisible over the camera housing (it is black there already), with a lip that grows below it while
/// the pointer rests and an accent line that fills toward opening. Without a housing, a short sliver at the top edge.
struct NotchTuckedView: View {
    let geometry: NotchGeometry
    let dwell: Double?
    let open: () -> Void

    var body: some View {
        let progress = dwell ?? 0
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                NotchShape(radius: geometry.hasNotch ? 10 : 3)
                    .fill(.black)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, (geometry.contentSize(for: .tucked).width - 24) * progress), height: 2)
                    .padding(.bottom, 2)
                    .opacity(dwell == nil ? 0 : 1)
            }
            .frame(height: geometry.contentSize(for: .tucked).height * (1 + 0.25 * progress))
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityLabel("OpenClicky")
        .accessibilityAddTraits(.isButton)
    }
}

/// A voice turn, a notice or always-on voice: the same pill the overlay showed, now in the notch, and clickable.
struct NotchActivityView: View {
    let geometry: NotchGeometry
    var stopTarget: NotchStopTarget?
    var stop: () -> Void = {}
    let open: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        NotchPill(turn: app.turn, timings: nil, showsTimings: false, micLevel: app.micLevel, notchWidth: geometry.notchWidth,
                  alwaysOn: app.alwaysOn, alwaysOnKeyPhrase: app.alwaysOnKeyPhrase)
            .frame(width: geometry.contentSize(for: .activity).width)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .overlay(alignment: .bottomTrailing) {
                if let stopTarget { NotchStopPill(target: stopTarget, stop: stop).padding(.trailing, 14).padding(.bottom, 9) }
            }
    }
}

/// The pill's Stop: ends the answer, the drawing, the drive or always-on through their usual stop paths.
struct NotchStopPill: View {
    let target: NotchStopTarget
    let stop: () -> Void

    var body: some View {
        Button(action: stop) {
            HStack(spacing: 4) {
                Image(systemName: target == .drawing ? "eraser.fill" : "stop.fill").font(.system(size: 9, weight: .bold))
                Text(target.title).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(Capsule().fill(.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(target == .drawing ? "Clear the drawing" : "Stop")
    }
}

// MARK: - Live events

struct NotchLiveEventCard: View {
    let event: NotchLiveEvent
    let geometry: NotchGeometry
    let now: Date
    let progress: Double?
    let send: (NotchInput) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 11) {
                ZStack {
                    Circle().fill(event.tone.color.opacity(0.18))
                    if let progress {
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(event.tone.color.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.2), value: progress)
                    }
                    Image(systemName: event.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(event.tone.color)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    if let subtitle = event.subtitle(now: now) {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(event.hasButtons ? 1 : 2)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 4)
                Button { send(.dismiss(event.id)) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .contentShape(Rectangle())
            .onTapGesture { send(.clickEvent(event.id)) }
            let buttons = event.actions.filter { if case .dismiss = $0.kind { false } else { true } }
            if !buttons.isEmpty {
                HStack(spacing: 8) {
                    ForEach(buttons) { action in
                        NotchActionButton(action: action, tint: event.tone.color) { send(.perform(eventID: event.id, actionID: action.id)) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 43)
            }
        }
        .foregroundStyle(.white)
        .padding(.top, geometry.notchHeight + 9)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(width: geometry.contentSize(for: .liveEvent(event)).width,
               height: geometry.contentSize(for: .liveEvent(event)).height, alignment: .top)
        .background(NotchShape(radius: 22).fill(.black))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }
}

struct NotchActionButton: View {
    let action: NotchAction
    let tint: Color
    let run: () -> Void

    var body: some View {
        Button(action: run) {
            HStack(spacing: 5) {
                if let symbol = action.symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
                Text(action.title).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .foregroundStyle(action.isPrimary ? .black : .white)
            .background(Capsule().fill(action.isPrimary ? tint : .white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

struct NotchOnboardingCard: View {
    let geometry: NotchGeometry
    let continueSetup: () -> Void
    let later: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.accentColor.opacity(0.2)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finish setting up OpenClicky").font(.system(size: 13.5, weight: .semibold))
                    Text("A few steps left: models, keys and permissions.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                NotchActionButton(action: NotchAction(id: "continue", title: "Continue", symbol: "arrow.right", kind: .dismiss, isPrimary: true),
                                  tint: .accentColor, run: continueSetup)
                NotchActionButton(action: NotchAction(id: "later", title: "Later", kind: .dismiss), tint: .accentColor, run: later)
            }
            .padding(.leading, 43)
        }
        .foregroundStyle(.white)
        .padding(.top, geometry.notchHeight + 10)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(width: geometry.contentSize(for: .onboarding).width, height: geometry.contentSize(for: .onboarding).height, alignment: .top)
        .background(NotchShape(radius: 22).fill(.black))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }
}

// MARK: - Open

struct NotchOpenPanel: View {
    let tab: NotchTab
    let geometry: NotchGeometry
    let controller: NotchController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(NotchTab.allCases, id: \.self) { item in
                    Button { controller.model.send(.selectTab(item)) } label: {
                        Label(item.title, systemImage: item.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .foregroundStyle(item == tab ? .black : .white.opacity(0.85))
                            .background(Capsule().fill(item == tab ? .white : .white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Button { controller.model.send(.clickOutside) } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fold the notch")
            }
            .padding(.top, geometry.notchHeight + 10)
            .padding(.horizontal, 18)
            Group {
                switch tab {
                case .home: NotchHomeTab(controller: controller)
                case .chat: NotchChatTab(controller: controller)
                case .settings: NotchSettingsTab(controller: controller)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(.white)
        .frame(width: geometry.contentSize(for: .open(tab)).width, height: geometry.contentSize(for: .open(tab)).height, alignment: .top)
        .background(NotchShape(radius: 28).fill(.black))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}

private struct NotchSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NotchRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(tint.opacity(0.16)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(1) }
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
    }
}

struct NotchHomeTab: View {
    let controller: NotchController
    @Environment(NotchModel.self) private var notch
    @Environment(AppModel.self) private var app
    @Environment(HomeServices.self) private var home

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(Color.accentColor)
                Text("\(home.talkKeys.settings.voice.phrase) and talk, or use Chat to type.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.8))
            }
            if let meeting = notch.meeting, case .meetingCountdown = meeting.kind {
                NotchSection(title: "Next meeting") {
                    NotchRow(symbol: meeting.symbol, tint: meeting.tone.color, title: meeting.title, detail: meeting.subtitle(now: notch.clock)) {
                        if let primary = meeting.actions.first(where: \.isPrimary) {
                            NotchActionButton(action: primary, tint: meeting.tone.color) {
                                controller.model.send(.perform(eventID: meeting.id, actionID: primary.id))
                            }
                        }
                    }
                }
            }
            NotchSection(title: "Background jobs") {
                let active = home.agentHUD?.feed.active ?? []
                if active.isEmpty {
                    Text("Nothing running. Ask for something that takes a while and it runs here.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                } else {
                    ForEach(active.prefix(3)) { item in
                        NotchRow(symbol: item.record.status == .needsYou ? "hand.raised.fill" : "gearshape.2.fill",
                                 tint: item.record.status == .needsYou ? NotchTone.attention.color : NotchTone.info.color,
                                 title: item.record.agentName ?? item.record.title, detail: item.headline) {
                            NotchActionButton(action: NotchAction(id: "show", title: "Show", kind: .openJob(item.id)), tint: .accentColor) {
                                home.agents?.panel.show()
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                NotchActionButton(action: NotchAction(id: "home", title: "Open Home", symbol: "house", kind: .dismiss, isPrimary: true),
                                  tint: .accentColor, run: controller.openHome)
                NotchActionButton(action: NotchAction(id: "jobs", title: home.agents?.panel.isVisible == true ? "Hide jobs" : "Show jobs",
                                                      symbol: "list.bullet.rectangle", kind: .dismiss), tint: .accentColor) {
                    home.agents?.panel.toggle()
                }
                NotchActionButton(action: NotchAction(id: "always", title: app.alwaysOn.isActive ? "Stop always-on" : "Always-on voice",
                                                      symbol: "dot.radiowaves.left.and.right", kind: .dismiss), tint: .accentColor) {
                    app.voiceLoop?.toggleAlwaysOn()
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct NotchChatTab: View {
    let controller: NotchController
    @Environment(NotchModel.self) private var notch
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var notch = notch
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble.fill").foregroundStyle(Color.accentColor)
                TextField("", text: $notch.draft, prompt: Text("Ask about what's on your screen…").foregroundStyle(.white.opacity(0.55)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14.5))
                    .focused($focused)
                    .onSubmit(send)
                if app.turn.kind == .typed, app.turn.phase.isBusy {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)) }
                        .buttonStyle(.plain)
                        .disabled(notch.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.09)))

            if notch.presentation == .textResponse {
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        if app.turn.kind == .typed {
                            if let words = app.turn.words {
                                Text(words).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                            }
                            if let status = app.turn.status {
                                Label(status, systemImage: "magnifyingglass").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.7))
                            }
                            ForEach(Array(app.turn.lines.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                            }
                            if let notice = app.turn.notice {
                                Label(notice.title, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12.5))
                                    .foregroundStyle(NotchTone.warning.color)
                            }
                        } else {
                            Text(app.alwaysOn.isActive ? "Answered aloud in your always-on conversation." : "Sent.")
                                .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
            } else {
                Text("Return sends. The answer is drawn on your screen and shows here. Esc or a click elsewhere folds the notch.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 0)
            }
        }
        .onAppear { focused = true }
        .onChange(of: notch.composerFocusToken) { _, _ in focused = true }
        .onExitCommand { controller.model.send(.escape) }
    }

    private func send() {
        let text = notch.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        notch.draft = ""
        controller.model.send(.submitText(text))
    }
}

struct NotchSettingsTab: View {
    let controller: NotchController
    @Environment(NotchModel.self) private var notch
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NotchSection(title: "Notch") {
                toggle("Open when the pointer rests on the notch", \.hoverOpens)
                toggle("Count down to my next meeting", \.meetingCountdown)
                toggle("Show background jobs starting and finishing", \.jobEvents)
                toggle("Copy spoken replies when my Mac is muted", \.copiesReplyWhenMuted)
            }
            NotchSection(title: "Voice") {
                voiceToggle("Captions while speaking", \.showsCaptions)
                voiceToggle("Sounds when listening starts and stops", \.playsCues)
                voiceToggle("Read typed answers aloud", \.speaksTypedAnswers)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                NotchActionButton(action: NotchAction(id: "settings", title: "All Settings…", symbol: "gearshape", kind: .dismiss, isPrimary: true),
                                  tint: .accentColor, run: controller.openSettings)
                Spacer(minLength: 0)
            }
        }
    }

    private func toggle(_ title: String, _ key: WritableKeyPath<NotchSettings, Bool>) -> some View {
        Toggle(isOn: Binding(get: { notch.settings[keyPath: key] }, set: { value in
            var settings = notch.settings
            settings[keyPath: key] = value
            controller.update(settings)
        })) {
            Text(title).font(.system(size: 12.5))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(.accentColor)
    }

    private func voiceToggle(_ title: String, _ key: WritableKeyPath<VoiceLoopSettings, Bool>) -> some View {
        Toggle(isOn: Binding(get: { app.voiceLoopSettings[keyPath: key] }, set: { value in
            var settings = app.voiceLoopSettings
            settings[keyPath: key] = value
            if let loop = app.voiceLoop { loop.update(settings) } else { app.voiceLoopSettings = settings }
        })) {
            Text(title).font(.system(size: 12.5))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(.accentColor)
    }
}
