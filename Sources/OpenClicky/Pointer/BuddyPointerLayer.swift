import AppKit
import OpenClickyKit
import SwiftUI

/// The buddy pointer as seen on one display. Mount one per overlay panel, filling it:
///
///     BuddyPointerLayer(screenFrame: screen.frame, controller: model.pointer)
///
/// Every display draws the part of the gesture that falls on it, so a flight between displays crosses the seam
/// seamlessly. Only the small area the frame paints is redrawn, and nothing runs while the buddy is idle.
struct BuddyPointerLayer: View {
    /// The display's frame in AppKit global points (`NSScreen.frame`).
    let screenFrame: CGRect
    let controller: BuddyPointerController

    var body: some View {
        ZStack(alignment: .topLeading) {
            if controller.isActive {
                TimelineView(.animation) { timeline in
                    painted(controller.frame(at: timeline.date))
                }
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func painted(_ frame: PointerFrame?) -> some View {
        let canvasSize = screenFrame.size
        let style = controller.style
        if let frame {
            let bounds = BuddyPointerArtist.paintedBounds(frame, display: screenFrame, canvasSize: canvasSize, style: style)
                .intersection(CGRect(origin: .zero, size: canvasSize))
            if !bounds.isNull, bounds.width >= 1, bounds.height >= 1 {
                let display = screenFrame
                Canvas { context, _ in
                    context.withCGContext { cg in
                        cg.translateBy(x: -bounds.minX, y: -bounds.minY)
                        BuddyPointerArtist.draw(frame, in: cg, display: display, canvasSize: canvasSize, style: style)
                    }
                }
                .frame(width: bounds.width, height: bounds.height)
                .position(x: bounds.midX, y: bounds.midY)
            }
        }
    }
}
