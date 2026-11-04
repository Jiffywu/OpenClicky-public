import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import OpenClickyKit

@Suite("Take-over safety checks")
struct TakeoverSafetyTests {
    static let textEdit = DriveTargetInfo(ownerPID: 4242, ownerBundleID: "com.apple.TextEdit", ownerName: "TextEdit",
                                          role: "AXTextField")
    static let password = DriveTargetInfo(ownerPID: 4242, ownerBundleID: "com.apple.TextEdit", ownerName: "TextEdit",
                                          role: "AXTextField", subrole: "AXSecureTextField")

    static func probe(focused: DriveTargetInfo? = textEdit, secureInput: Bool = false) -> StaticTakeoverProbe {
        StaticTakeoverProbe(regions: [
            .init(frame: CGRect(x: 0, y: 0, width: 100, height: 100), info: password),
            .init(frame: CGRect(x: 100, y: 0, width: 100, height: 100),
                  info: DriveTargetInfo(ownerPID: 77, ownerBundleID: "com.apple.SecurityAgent", ownerName: "SecurityAgent")),
            .init(frame: CGRect(x: 200, y: 0, width: 100, height: 100),
                  info: DriveTargetInfo(ownerPID: 999, ownerBundleID: "dev.openclicky.app", ownerName: "OpenClicky")),
            .init(frame: CGRect(x: 300, y: 0, width: 100, height: 100),
                  info: DriveTargetInfo(ownerPID: 55, ownerBundleID: nil, ownerName: "System Settings")),
            .init(frame: CGRect(x: 0, y: 0, width: 2000, height: 2000), info: textEdit),
        ], focused: focused, secureInput: secureInput)
    }

    static func safety(focused: DriveTargetInfo? = textEdit, secureInput: Bool = false) -> TakeoverSafetyGuard {
        TakeoverSafetyGuard(policy: .standard(ownProcessID: 999, ownBundleID: "dev.openclicky.app"),
                            probe: probe(focused: focused, secureInput: secureInput))
    }

    @Test func ordinaryActionsPass() async {
        let safety = Self.safety()
        #expect(await safety.check(.click(at: CGPoint(x: 600, y: 600), button: .left, count: 1, modifiers: [])) == nil)
        #expect(await safety.check(.type("Quarterly plan")) == nil)
        #expect(await safety.check(.key(KeyCombo.parse("super+s")!, repeatCount: 1)) == nil)
        #expect(await safety.check(.scroll(at: CGPoint(x: 600, y: 600), direction: .down, amount: 5, modifiers: [])) == nil)
        // Hovering is allowed anywhere, even over a password field.
        #expect(await safety.check(.move(to: CGPoint(x: 50, y: 50))) == nil)
    }

    @Test func refusesPasswordFieldsAndSecureInput() async {
        let safety = Self.safety()
        #expect(await safety.check(.click(at: CGPoint(x: 50, y: 50), button: .left, count: 1, modifiers: [])) == .passwordField)
        #expect(await safety.check(.mouseDown(at: CGPoint(x: 50, y: 50))) == .passwordField)
        #expect(await safety.check(.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 600, y: 600), modifiers: [])) == .passwordField)
        #expect(await Self.safety(focused: Self.password).check(.type("hunter2")) == .passwordField)
        #expect(await Self.safety(focused: Self.password).check(.key(KeyCombo.parse("Return")!, repeatCount: 1)) == .passwordField)
        #expect(await Self.safety(secureInput: true).check(.type("hunter2")) == .secureInput)
    }

    @Test func refusesSystemDialogsSettingsAndOwnWindows() async {
        let safety = Self.safety()
        #expect(await safety.check(.click(at: CGPoint(x: 150, y: 50), button: .left, count: 1, modifiers: []))
            == .systemWindow("SecurityAgent"))
        #expect(await safety.check(.click(at: CGPoint(x: 350, y: 50), button: .left, count: 1, modifiers: []))
            == .systemWindow("System Settings"))
        #expect(await safety.check(.click(at: CGPoint(x: 250, y: 50), button: .left, count: 1, modifiers: [])) == .ownWindow)
        // Dragging something onto a system dialog is refused too.
        #expect(await safety.check(.drag(from: CGPoint(x: 600, y: 600), to: CGPoint(x: 150, y: 50), modifiers: []))
            == .systemWindow("SecurityAgent"))
        // Typing while a system prompt has focus.
        let prompt = DriveTargetInfo(ownerPID: 77, ownerBundleID: "com.apple.SecurityAgent", ownerName: "SecurityAgent", role: "AXTextField")
        #expect(await Self.safety(focused: prompt).check(.type("admin")) == .systemWindow("SecurityAgent"))
        let own = DriveTargetInfo(ownerPID: 999, ownerName: "OpenClicky")
        #expect(await Self.safety(focused: own).check(.key(KeyCombo.parse("Return")!, repeatCount: 1)) == .ownWindow)
    }

    @Test func refusesDangerousShortcuts() async {
        let safety = Self.safety()
        // Extra modifiers do not make a dangerous shortcut safe: holding shift+option+cmd+Escape force-quits the front
        // app at once.
        for text in ["super+alt+Escape", "ctrl+super+q", "shift+super+q", "alt+shift+super+q", "shift+super+BackSpace",
                     "alt+shift+cmd+Delete", "shift+alt+super+Escape", "ctrl+shift+super+q", "ctrl+alt+shift+super+BackSpace"] {
            let combo = KeyCombo.parse(text)!
            #expect(await safety.check(.key(combo, repeatCount: 1)) == .forbiddenShortcut(combo.summary), "\(text)")
            #expect(await safety.check(.holdKey(combo, seconds: 1)) == .forbiddenShortcut(combo.summary), "\(text)")
        }
        // Close relatives that are fine: quit one app, delete a word.
        #expect(await safety.check(.key(KeyCombo.parse("super+q")!, repeatCount: 1)) == nil)
        #expect(await safety.check(.key(KeyCombo.parse("alt+BackSpace")!, repeatCount: 1)) == nil)
    }

    @Test func refusesOversizedOrControlText() async {
        let safety = Self.safety()
        #expect(await safety.check(.type(String(repeating: "a", count: 2001))) == .textTooLong(count: 2001, limit: 2000))
        #expect(await safety.check(.type("ok\u{7}bell")) == .controlCharacters)
        #expect(await safety.check(.type("line one\nline two\tcol")) == nil)
        #expect(await safety.check(.key(KeyCombo.parse("Down")!, repeatCount: 51)) != nil)
        #expect(await safety.check(.holdKey(KeyCombo.parse("shift")!, seconds: 30)) != nil)
        #expect(await safety.check(.scroll(at: CGPoint(x: 600, y: 600), direction: .down, amount: 31, modifiers: [])) != nil)
    }

    @Test func refusalTextIsForTheModel() {
        #expect(DriveRefusal.passwordField.description.hasPrefix("Refused:"))
        #expect(DriveRefusal.systemWindow("SecurityAgent").description.contains("SecurityAgent"))
        #expect(DriveRefusal.forbiddenShortcut("ctrl+cmd+q").code == "forbidden_shortcut")
    }

    @Test func staticProbeAnswersFromObservationElements() async {
        let observation = TakeoverFixtures.observation()
        let probe = StaticTakeoverProbe(regions: StaticTakeoverProbe.regions(for: observation))
        let safety = TakeoverSafetyGuard(probe: probe)
        let point = try! observation.mapper.quartzPoint(for: .element("e3"))
        #expect(await safety.check(.click(at: point, button: .left, count: 1, modifiers: [])) == .passwordField)
        let title = try! observation.mapper.quartzPoint(for: .element("e2"))
        #expect(await safety.check(.click(at: title, button: .left, count: 1, modifiers: [])) == nil)
    }

    /// Keystrokes go to the front app even when no element reports focus (or Accessibility is off), so the live probe
    /// answers with the front app then; otherwise typing into System Settings or OpenClicky would go unchecked.
    @Test func keyboardTargetFallsBackToTheFrontApp() async {
        let own = ProcessInfo.processInfo.processIdentifier
        let target = MacTakeoverProbe.keyboardTarget(focused: nil, frontPID: own)
        #expect(target?.ownerPID == own)
        let policy = TakeoverSafetyPolicy.standard(ownProcessID: own, ownBundleID: nil)
        #expect(await TakeoverSafetyGuard(policy: policy, probe: StaticTakeoverProbe(focused: target)).check(.type("x")) == .ownWindow)
        let focused = DriveTargetInfo(ownerPID: 1, ownerName: "TextEdit", role: "AXTextArea")
        #expect(MacTakeoverProbe.keyboardTarget(focused: focused, frontPID: own) == focused)
        #expect(MacTakeoverProbe.keyboardTarget(focused: nil, frontPID: nil) == nil)
    }

    /// Read-only: asks the window server which app is in front and posts nothing.
    @Test func liveProbeAlwaysNamesWhereKeystrokesGo() async {
        guard await MainActor.run(body: { NSWorkspace.shared.frontmostApplication }) != nil else { return }
        #expect(await MacTakeoverProbe().focusedTarget()?.ownerPID != nil)
    }
}

@Suite("User input while driving")
struct UserInputPolicyTests {
    @Test func escapeStopsAndIsSwallowedWithItsKeyUp() {
        var policy = UserInputPolicy()
        let down = policy.decide(.keyDown(keyCode: Int64(kVK_Escape)), synthetic: false)
        #expect(down == UserInputPolicy.Decision(swallow: true, stop: .userPressedEscape))
        #expect(policy.decide(.keyUp(keyCode: Int64(kVK_Escape)), synthetic: false).swallow)
        // After the stop, everything passes.
        #expect(policy.decide(.mouseButton, synthetic: false) == .pass)
    }

    @Test func anyOtherInputMeansTheUserTookOver() {
        for kind in [UserInputKind.keyDown(keyCode: Int64(kVK_ANSI_A)), .mouseButton, .scroll] {
            var policy = UserInputPolicy()
            #expect(policy.decide(kind, synthetic: false).stop == .userTookOver)
        }
    }

    @Test func smallMovementsAreToleratedThenStop() {
        var policy = UserInputPolicy(moveTolerance: 24)
        #expect(policy.decide(.pointerMoved(distance: 10), synthetic: false) == .pass)
        #expect(policy.decide(.pointerMoved(distance: 10), synthetic: false) == .pass)
        let third = policy.decide(.pointerMoved(distance: 10), synthetic: false)
        #expect(third.stop == .userTookOver && !third.swallow)
    }

    @Test func movementRightAfterArmingIsForgivenButKeysAndClicksAreNot() {
        var policy = UserInputPolicy(moveTolerance: 24, movementGraceSeconds: 1)
        #expect(policy.decide(.pointerMoved(distance: 300), synthetic: false, elapsed: 0.4) == .pass)
        #expect(policy.moved == 0)
        #expect(policy.decide(.pointerMoved(distance: 30), synthetic: false, elapsed: 1.5).stop == .userTookOver)
        var early = UserInputPolicy()
        #expect(early.decide(.mouseButton, synthetic: false, elapsed: 0.1).stop == .userTookOver)
        var escape = UserInputPolicy()
        #expect(escape.decide(.keyDown(keyCode: Int64(kVK_Escape)), synthetic: false, elapsed: 0).stop == .userPressedEscape)
    }

    @Test func syntheticEventsAndModifiersNeverStop() {
        var policy = UserInputPolicy()
        #expect(policy.decide(.keyDown(keyCode: Int64(kVK_Escape)), synthetic: true) == .pass)
        #expect(policy.decide(.mouseButton, synthetic: true) == .pass)
        #expect(policy.decide(.pointerMoved(distance: 500), synthetic: true) == .pass)
        #expect(policy.decide(.modifiersChanged, synthetic: false) == .pass)
        #expect(policy.stopped == nil)
    }
}
