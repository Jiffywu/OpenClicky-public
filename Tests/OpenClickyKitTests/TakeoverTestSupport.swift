import CoreGraphics
import Foundation
import os
@testable import OpenClickyKit

/// A 1512×982 pt Retina panel as primary, and a 1920×1080 monitor to its left with top edges aligned.
enum TakeoverFixtures {
    static let main = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2, isPrimary: true)
    static let left = DisplayGeometry(id: 2, frame: CGRect(x: -1920, y: -98, width: 1920, height: 1080), scale: 1, isPrimary: false)
    static let layout = DesktopLayout(displays: [main, left])

    static let image: Data = (try? DriveImageTools.placeholder(width: 1280, height: 831)) ?? Data()

    /// A 1280×831 screenshot of the main display, with a few elements.
    static func observation(display: DisplayGeometry = main, width: Int = 1280, height: Int = 831,
                            elements: [DriveElement] = defaultElements) -> DriveObservation {
        DriveObservation(imageData: image, pixelWidth: width, pixelHeight: height, display: display, layout: layout, elements: elements,
                         frontApp: FrontAppInfo(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit", processIdentifier: 4242),
                         windowTitle: "Untitled")
    }

    /// AppKit frames on the main display: a Save button near the top-left, a title field, a password field.
    static let defaultElements: [DriveElement] = [
        DriveElement(id: "e1", role: "AXButton", label: "Save", frame: CGRect(x: 100, y: 882, width: 80, height: 30)),
        DriveElement(id: "e2", role: "AXTextField", label: "Title", frame: CGRect(x: 200, y: 800, width: 300, height: 24)),
        DriveElement(id: "e3", role: "AXTextField", subrole: "AXSecureTextField", label: nil, frame: CGRect(x: 200, y: 700, width: 300, height: 24)),
    ]
}

/// A screen that hands out the same observation, counts screenshots, and can fail on a given screenshot.
final class TakeoverCountingScreen: TakeoverScreenSource {
    private let state = OSAllocatedUnfairLock(initialState: 0)
    let observation: DriveObservation
    let failOn: Int?

    init(_ observation: DriveObservation = TakeoverFixtures.observation(), failOn: Int? = nil) {
        self.observation = observation
        self.failOn = failOn
    }

    var count: Int { state.withLock { $0 } }

    func observe() async throws -> DriveObservation {
        let n = state.withLock { count -> Int in
            count += 1
            return count
        }
        if n == failOn { throw ScreenCaptureError.permissionDenied }
        return observation
    }
}

/// A language model that replays scripted replies and records requests.
final class TakeoverScriptedModel: LanguageModelClient {
    private let state: OSAllocatedUnfairLock<(replies: [[ChatEvent]], requests: [ChatRequest])>

    init(_ replies: [[ChatEvent]]) {
        state = OSAllocatedUnfairLock(initialState: (replies, []))
    }

    var requests: [ChatRequest] { state.withLock { $0.requests } }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let events = state.withLock { state -> [ChatEvent] in
            state.requests.append(request)
            return state.replies.isEmpty ? [.textDelta("done"), .finished(.stop)] : state.replies.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

extension DrivePlan {
    static func acting(_ actions: [(String, JSONValue)]) -> DrivePlan { acting("", actions) }

    static func acting(_ narration: String, _ actions: [(String, JSONValue)]) -> DrivePlan {
        DrivePlan(narration: narration, actions: actions.enumerated().map { index, item in
            PlannedAction.parsing(callID: "c\(index)", name: item.0, input: item.1)
        })
    }
}

/// Collects events in order.
final class TakeoverEventLog: Sendable {
    private let state = OSAllocatedUnfairLock<[TakeoverEvent]>(initialState: [])
    func record(_ event: TakeoverEvent) { state.withLock { $0.append(event) } }
    var events: [TakeoverEvent] { state.withLock { $0 } }
}
