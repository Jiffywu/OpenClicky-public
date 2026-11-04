import SwiftUI

/// What the dictation HUD shows, already in words. Kept free of OpenClickyKit for standalone rendering checks.
struct DictationHUDContent: Equatable {
    enum Tone: Equatable {
        /// Listening while the keys are held.
        case listening
        /// Listening, locked on hands-free.
        case handsFree
        /// Finishing, tidying, typing.
        case working
        case success
        /// Something the user should know but nothing went wrong (copied to clipboard, learned a word).
        case notice
        case warning
    }

    var tone: Tone
    var symbol: String
    var title: String
    var detail: String?
    /// Microphone level, 0…1, for the bars while listening.
    var level: Double = 0

    var showsLevel: Bool { tone == .listening || tone == .handsFree }
}

/// A small pill near the field being dictated into.
struct DictationHUDView: View {
    let content: DictationHUDContent

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(accent.opacity(0.22)).frame(width: 26, height: 26)
                Image(systemName: content.symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
            }
            if content.showsLevel {
                LevelBars(level: content.level, color: accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(content.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.head)
                if let detail = content.detail {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.11).opacity(0.94))
                .overlay(Capsule(style: .continuous).strokeBorder(accent.opacity(0.35), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        .fixedSize()
        .animation(.easeOut(duration: 0.12), value: content.level)
    }

    private var accent: Color {
        switch content.tone {
        case .listening: Color(red: 1.0, green: 0.36, blue: 0.33)
        case .handsFree: Color(red: 1.0, green: 0.58, blue: 0.2)
        case .working: Color(red: 0.55, green: 0.68, blue: 1.0)
        case .success: Color(red: 0.32, green: 0.85, blue: 0.5)
        case .notice: Color(red: 0.98, green: 0.82, blue: 0.3)
        case .warning: Color(red: 1.0, green: 0.45, blue: 0.4)
        }
    }
}

/// Five bars that rise with the microphone level.
private struct LevelBars: View {
    let level: Double
    let color: Color
    private let shape: [Double] = [0.45, 0.75, 1.0, 0.75, 0.45]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(shape.indices, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: 4 + 14 * min(1, max(0, level)) * shape[index])
            }
        }
        .frame(height: 18)
    }
}
