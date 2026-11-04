import AppKit
import OpenClickyKit
import SwiftUI

/// The pill at the top centre of the screen (hanging from the notch on Macs that have one): what OpenClicky is doing,
/// what it heard while the keys are held, what it is looking up, and short notices. While always-on voice runs it
/// shows that conversation instead (the voice loop's turns are held meanwhile).
struct NotchPill: View {
    let turn: TurnDisplay
    let timings: TurnTimings?
    let showsTimings: Bool
    let micLevel: () -> Float
    /// Width of the hardware notch (0 without one); the pill is at least this wide so it reads as part of it.
    let notchWidth: CGFloat
    var alwaysOn = AlwaysOnDisplay()
    /// "Triple-tap Control", to say how always-on stops.
    var alwaysOnKeyPhrase: String?

    var body: some View {
        if let content {
            HStack(alignment: .center, spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let detail = content.detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(2)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.top, notchWidth > 0 ? 34 : 9)
            .padding(.bottom, 10)
            .frame(minWidth: max(notchWidth + 40, 240), maxWidth: 460)
            .fixedSize(horizontal: false, vertical: true)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18, style: .continuous).fill(.black))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private struct Content {
        var title: String
        var detail: String?
    }

    private var alwaysOnNotch: AlwaysOnDisplay.Notch? {
        guard turn.phase == .idle else { return nil }
        return alwaysOn.notch(stopHint: alwaysOnKeyPhrase.map { "\($0) ends it" })
    }

    private var content: Content? {
        if let notch = alwaysOnNotch { return Content(title: notch.title, detail: notch.detail) }
        if let notice = turn.notice, !turn.phase.isBusy || turn.phase == .idle {
            return Content(title: notice.title, detail: notice.detail)
        }
        switch turn.phase {
        case .idle:
            guard showsTimings, let timings, let heard = timings.originToFirstLineHeardMs else { return nil }
            return Content(title: "Last answer", detail: "first line heard \(heard) ms after release · total \(timings.totalMs ?? 0) ms")
        case .listening:
            return Content(title: "Listening…", detail: turn.liveTranscript.isEmpty ? "Let go when you're done" : turn.liveTranscript)
        case .transcribing:
            return Content(title: "Got it", detail: turn.liveTranscript.isEmpty ? nil : turn.liveTranscript)
        case .capturing:
            return Content(title: "Looking at your screen…", detail: turn.words)
        case .requesting:
            return Content(title: turn.status ?? "Thinking…", detail: turn.words)
        case .speaking:
            return Content(title: turn.status ?? (turn.usingFallbackVoice ? "Speaking (Mac voice)" : "Speaking"), detail: turn.words)
        case .drawing:
            return Content(title: turn.status ?? "Drawing", detail: turn.words)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let notch = alwaysOnNotch {
            switch notch.icon {
            case .listening:
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                    LevelBars(level: CGFloat(micLevel()))
                }
                .frame(width: 22, height: 18)
            case .working:
                ProgressView().controlSize(.small).tint(.white)
                    .frame(width: 22, height: 18)
            case .speaking:
                Image(systemName: "speaker.wave.2.fill").frame(width: 22, height: 18)
            }
        } else {
            turnIcon
        }
    }

    @ViewBuilder
    private var turnIcon: some View {
        switch turn.phase {
        case .listening:
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                LevelBars(level: CGFloat(micLevel()))
            }
            .frame(width: 22, height: 18)
        case .transcribing, .capturing, .requesting:
            ProgressView().controlSize(.small).tint(.white)
                .frame(width: 22, height: 18)
        case .speaking:
            Image(systemName: "speaker.wave.2.fill").frame(width: 22, height: 18)
        case .drawing:
            Image(systemName: "pencil.tip").frame(width: 22, height: 18)
        case .idle:
            Image(systemName: turn.notice?.tone == .info ? "ear" : "exclamationmark.triangle.fill")
                .foregroundStyle(turn.notice?.tone == .error ? .orange : .white)
                .frame(width: 22, height: 18)
        }
    }
}

/// Five bars that follow the mic level.
private struct LevelBars: View {
    let level: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let shape: [CGFloat] = [0.45, 0.75, 1, 0.75, 0.45]
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: max(3, 16 * min(1, level * 3 + 0.08) * shape[index]))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

/// The line being spoken, as a caption near the bottom of the screen. With `revealed`, the words heard so far are
/// bright and the rest wait faintly in place (so the lines don't reflow as words arrive); `beats` adds the drawing's
/// debug chips underneath.
struct CaptionPlate: View {
    let text: String
    var revealed: Int?
    var size: CGFloat = 17
    var beats: DrawingBeats?

    var body: some View {
        VStack(spacing: 8) {
            caption
                .font(.system(size: size, weight: .medium))
                .multilineTextAlignment(.center)
            if let beats { BeatChips(beats: beats) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: 760)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.72)))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .id(text)
    }

    private var caption: Text {
        guard let revealed else { return Text(text).foregroundColor(.white) }
        let parts = CaptionWords(text).split(revealed: revealed)
        return Text(parts.heard).foregroundColor(.white) + Text(parts.coming).foregroundColor(.white.opacity(0.28))
    }
}

/// The drawing's beat under the caption, for tuning drawings: "beat 2 of 4 · 1.2 s / 3.0 s" and a chip for each
/// statement of the line, grey while it waits, blue while it draws, green when done, outlined orange when it runs late.
struct BeatChips: View {
    let beats: DrawingBeats

    var body: some View {
        VStack(spacing: 5) {
            Text(beats.header)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 5) {
                ForEach(Array(beats.chips.prefix(8).enumerated()), id: \.offset) { _, chip in
                    Text(chip.label)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .foregroundStyle(chip.state == .waiting ? .white.opacity(0.75) : .white)
                        .background(Capsule().fill(color(chip.state)))
                        .overlay(Capsule().strokeBorder(chip.late ? Color.orange : .clear, lineWidth: 1.5))
                }
            }
        }
    }

    private func color(_ state: DrawingBeats.Chip.State) -> Color {
        switch state {
        case .waiting: .white.opacity(0.14)
        case .drawing: .accentColor.opacity(0.85)
        case .done: .green.opacity(0.7)
        }
    }
}

/// A small bubble by the pointer while the keys are held, with a waveform that follows the mic.
struct ListeningBubble: View {
    let turn: TurnDisplay
    var level: () -> Float = { 0 }

    var body: some View {
        HStack(spacing: 8) {
            if turn.phase == .listening {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                    LevelBars(level: CGFloat(level()))
                }
                .frame(width: 22, height: 16)
            } else {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            }
            if turn.phase == .listening {
                Text(turn.liveTranscript.isEmpty ? "Listening" : turn.liveTranscript)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .frame(maxWidth: 280, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.accentColor.opacity(0.92)))
        .shadow(color: .accentColor.opacity(0.5), radius: 10)
        .fixedSize()
    }

    private var icon: String {
        switch turn.phase {
        case .listening: "waveform"
        case .speaking: "speaker.wave.2.fill"
        default: "ellipsis"
        }
    }
}
