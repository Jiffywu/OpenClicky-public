// Run on an unlocked Mac after `swift build --product OpenClicky`:
// swiftc -parse-as-library -I .build/debug .build/debug/OpenClickyKit.o \
//   Sources/OpenClicky/Support/ViewState.swift Sources/OpenClicky/Agents/AgentHUD{Model,View,Panel}.swift \
//   scripts/check-agent-panel.swift -o /tmp/check-agent-panel && /tmp/check-agent-panel
import AppKit
import Observation
import OpenClickyKit
import os

@main
struct AgentPanelCheck {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let now = Date()
        let job = AgentJobRecord(id: "panel-check", kind: .job, title: "Running job", task: "Panel check",
                                 harness: .codex, model: "fixture", provider: "fixture", status: .running,
                                 createdAt: now, updatedAt: now, runs: [], usage: .init(), folderPath: "/tmp/panel-check")
        let model = AgentHUDModel(records: [job], now: now)
        let panel = AgentHUDPanel(model: model)
        let invalidations = OSAllocatedUnfairLock(initialState: 0)

        func trackVisibility() {
            withObservationTracking { _ = panel.isVisible } onChange: {
                invalidations.withLock { $0 += 1 }
            }
        }

        precondition(!panel.isVisible, "Panel starts hidden")
        trackVisibility()
        panel.toggle()
        precondition(panel.isVisible, "The first menu selection shows the panel")
        guard let window = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }) else {
            fatalError("The panel must actually be on screen")
        }
        precondition(invalidations.withLock { $0 } == 1, "Showing the panel must refresh its menu checkmark")

        trackVisibility()
        panel.toggle()
        precondition(!panel.isVisible && !window.isVisible, "The second menu selection hides the panel")
        precondition(invalidations.withLock { $0 } == 2, "Hiding the panel must refresh its menu checkmark")

        trackVisibility()
        panel.show()
        precondition(panel.isVisible && window.isVisible, "A notification can reopen the panel")
        precondition(invalidations.withLock { $0 } == 3, "Opening outside the menu must refresh its checkmark")

        trackVisibility()
        window.close()
        precondition(!panel.isVisible && !window.isVisible, "Native window closure must clear the menu state")
        precondition(invalidations.withLock { $0 } == 4, "Window closure must refresh its menu checkmark")
        precondition(model.items.first?.record.status == .running, "Dismissing the panel must leave the job running")
        print("PASS: panel toggles, notification open, native close, observable menu state, job stays running")
    }
}
