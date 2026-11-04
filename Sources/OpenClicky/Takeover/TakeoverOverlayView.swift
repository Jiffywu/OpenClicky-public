import SwiftUI

/// What the drive overlay shows on one display. Plain values, so it renders offscreen for checks.
struct TakeoverOverlayContent: Equatable {
    /// "OpenClicky is using your Mac", "Done", "Stopped".
    var title: String = "OpenClicky is using your Mac"
    /// The current step in a few words ("Clicking “Save”").
    var detail: String?
    /// The drive cursor in this display's local points (top-left origin), when it is on this display.
    var cursor: CGPoint?
    var cursorLabel: String?
    var isDryRun: Bool = false
    var isStopping: Bool = false
    /// The user moved the mouse: say so before the drive hands back.
    var notice: String?
}

/// A red frame around the display, a status pill at the top, and the drive cursor where the next action lands.
/// Never takes clicks (its panel ignores mouse events) and is left out of the drive's own screenshots.
struct TakeoverOverlayView: View {
    let content: TakeoverOverlayContent
    let size: CGSize

    private var tint: Color { content.isDryRun ? .orange : .red }

    var body: some View {
        ZStack(alignment: .topLeading) {
            frame
            pill
                .frame(width: size.width)
                .padding(.top, 44)
            if let cursor = content.cursor {
                driveCursor.position(x: cursor.x, y: cursor.y)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var frame: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(tint.opacity(content.isStopping ? 0.45 : 0.9), lineWidth: 5)
            .shadow(color: tint.opacity(0.75), radius: 14)
            .shadow(color: tint.opacity(0.35), radius: 32)
            .frame(width: size.width, height: size.height)
    }

    private var pill: some View {
        HStack(spacing: 10) {
            Circle().fill(tint).frame(width: 9, height: 9).shadow(color: tint, radius: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(content.isDryRun ? "\(content.title) (dry run)" : content.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(content.notice ?? content.detail ?? "Press Esc to stop, or move the mouse to take back control.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("esc").font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.6)))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(.regularMaterial).shadow(color: .black.opacity(0.25), radius: 10, y: 4))
        .overlay(Capsule().strokeBorder(tint.opacity(0.5)))
    }

    private var driveCursor: some View {
        ZStack(alignment: .topLeading) {
            Circle().strokeBorder(tint, lineWidth: 2.5).frame(width: 30, height: 30)
                .background(Circle().fill(tint.opacity(0.16)))
                .shadow(color: tint.opacity(0.8), radius: 6)
            Image(systemName: "cursorarrow").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 1.5)
                .offset(x: 13, y: 11)
            if let label = content.cursorLabel {
                Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(tint))
                    .fixedSize()
                    .offset(x: 30, y: 30)
            }
        }
        .frame(width: 30, height: 30)
    }
}
