import SwiftUI

/// What the consent card shows. Plain values let the card render offscreen for checks.
struct TakeoverConsentCardContent: Equatable {
    var task: String
    var steps: [String]
    var app: String?
    /// Nothing will reach the Mac: the drive only shows what it would do.
    var isDryRun: Bool = false
}

/// "Let OpenClicky use your Mac?": the task, the plan, how to stop, and two buttons. Return approves and Escape
/// declines (the panel maps the keys); nothing happens until the user picks one.
struct TakeoverConsentCard: View {
    let content: TakeoverConsentCardContent
    var onApprove: () -> Void = {}
    var onDecline: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.red.opacity(0.14)).frame(width: 34, height: 34)
                    Image(systemName: "cursorarrow.motionlines").font(.system(size: 15, weight: .semibold)).foregroundStyle(.red)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Let OpenClicky use your Mac?").font(.system(size: 15, weight: .semibold))
                    Text(content.app.map { "In \($0)" } ?? "It will move the pointer and type for you")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if content.isDryRun {
                    Text("DRY RUN").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.18))).foregroundStyle(.orange)
                }
            }

            Text(content.task).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)

            if !content.steps.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(content.steps.prefix(8).enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1)").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                                .frame(width: 14, alignment: .trailing)
                            Text(step).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.05)))
            }

            VStack(alignment: .leading, spacing: 6) {
                rule("escape", "Press Esc to stop me at any time.")
                rule("hand.raised", "Touch the mouse or keyboard and I stop and hand it back.")
                rule("lock.shield", "I won't touch passwords, system prompts or settings.")
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(action: onDecline) {
                    Text("Not now").frame(minWidth: 72)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                Button(action: onApprove) {
                    Text(content.isDryRun ? "Show me the plan" : "Let OpenClicky drive").frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func rule(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 16)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}
