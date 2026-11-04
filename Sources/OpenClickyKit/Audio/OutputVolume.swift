import AudioToolbox
import CoreAudio
import Foundation

// Muted or silent output (docs/audio-robustness.md). A spoken reply into a muted Mac is lost: the voice loop checks the
// output before it speaks, answers silently instead (captions and drawing), copies the reply to the clipboard and offers
// to unmute or turn the volume up. Nothing here changes the volume unless the user presses one of those buttons.

/// Why the voice can't be heard.
public enum OutputSilence: String, Sendable, Hashable, Codable {
    case muted
    case zeroVolume = "zero_volume"
}

/// The default output device's mute switch and volume as CoreAudio reports them.
public struct OutputVolumeState: Sendable, Hashable {
    public var deviceName: String?
    public var deviceUID: String?
    /// Nil when the device has no mute control.
    public var muted: Bool?
    /// 0…1; nil when the device has no volume control (many HDMI and AirPlay outputs).
    public var volume: Float?

    public init(deviceName: String? = nil, deviceUID: String? = nil, muted: Bool?, volume: Float?) {
        self.deviceName = deviceName
        self.deviceUID = deviceUID
        self.muted = muted
        self.volume = volume
    }

    /// At or below this the output counts as silent (one notch of the volume keys is 1/16).
    public static let audibleFloor: Float = 0.001

    /// Why nothing would be heard, or nil. A device without controls is assumed audible.
    public var silence: OutputSilence? {
        if muted == true { return .muted }
        if let volume, volume <= Self.audibleFloor { return .zeroVolume }
        return nil
    }

    public var summary: String {
        let mute = muted.map { $0 ? "muted" : "not muted" } ?? "no mute control"
        let level = volume.map { "volume \(Int(($0 * 100).rounded()))%" } ?? "no volume control"
        return "\(deviceName ?? "unknown output"): \(mute), \(level)"
    }
}

/// Reads (and, only when the user asks, changes) the Mac's output mute and volume.
public protocol SystemOutputControlling: Sendable {
    /// The default output now; nil when there is no output device.
    func read() -> OutputVolumeState?
    func setMuted(_ muted: Bool) throws
    /// Sets the volume (0…1) and turns mute off.
    func setVolume(_ volume: Float) throws
}

public enum OutputVolumeError: Error, Sendable, Equatable, CustomStringConvertible {
    case noOutputDevice
    case notSettable(String)
    case failed(String, OSStatus)

    public var description: String {
        switch self {
        case .noOutputDevice: "There is no output device."
        case .notSettable(let what): "The output device doesn't let apps change its \(what)."
        case .failed(let what, let status): "Changing the \(what) failed (\(status))."
        }
    }
}

/// The default output device through CoreAudio. Reading needs no permission.
public struct CoreAudioOutputVolume: SystemOutputControlling {
    public init() {}

    public func read() -> OutputVolumeState? {
        guard let id = AudioDevices.defaultDeviceID(input: false) else { return nil }
        let info = AudioDevices.info(id)
        return OutputVolumeState(deviceName: info?.name, deviceUID: info?.uid, muted: Self.muted(id), volume: Self.volume(id))
    }

    public func setMuted(_ muted: Bool) throws {
        guard let id = AudioDevices.defaultDeviceID(input: false) else { throw OutputVolumeError.noOutputDevice }
        let elements = Self.settableElements(id, kAudioDevicePropertyMute)
        guard !elements.isEmpty else { throw OutputVolumeError.notSettable("mute") }
        for element in elements {
            var value: UInt32 = muted ? 1 : 0
            var address = Self.address(kAudioDevicePropertyMute, element: element)
            let status = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
            guard status == noErr else { throw OutputVolumeError.failed("mute", status) }
        }
    }

    public func setVolume(_ volume: Float) throws {
        guard let id = AudioDevices.defaultDeviceID(input: false) else { throw OutputVolumeError.noOutputDevice }
        var level = Float32(min(max(volume, 0), 1))
        var main = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, element: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(id, &main), AudioObjectIsPropertySettable(id, &main, &settable) == noErr, settable.boolValue {
            let status = AudioObjectSetPropertyData(id, &main, 0, nil, UInt32(MemoryLayout<Float32>.size), &level)
            guard status == noErr else { throw OutputVolumeError.failed("volume", status) }
        } else {
            let elements = Self.settableElements(id, kAudioDevicePropertyVolumeScalar)
            guard !elements.isEmpty else { throw OutputVolumeError.notSettable("volume") }
            for element in elements {
                var address = Self.address(kAudioDevicePropertyVolumeScalar, element: element)
                let status = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &level)
                guard status == noErr else { throw OutputVolumeError.failed("volume", status) }
            }
        }
        if Self.muted(id) == true { try setMuted(false) }
    }

    // MARK: CoreAudio

    static func address(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }

    /// The main element and the first two channels, the places devices put their controls.
    static let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]

    static func muted(_ id: AudioDeviceID) -> Bool? {
        var found: [Bool] = []
        for element in elements {
            var address = address(kAudioDevicePropertyMute, element: element)
            guard AudioObjectHasProperty(id, &address) else { continue }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { continue }
            // The main element decides when it has a switch; otherwise every channel must be muted.
            if element == kAudioObjectPropertyElementMain { return value != 0 }
            found.append(value != 0)
        }
        return found.isEmpty ? nil : found.allSatisfy { $0 }
    }

    static func volume(_ id: AudioDeviceID) -> Float? {
        var main = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, element: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(id, &main) {
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &main, 0, nil, &size, &value) == noErr { return Float(value) }
        }
        var levels: [Float] = []
        for element in elements {
            var address = address(kAudioDevicePropertyVolumeScalar, element: element)
            guard AudioObjectHasProperty(id, &address) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr { levels.append(Float(value)) }
        }
        return levels.max()
    }

    static func settableElements(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> [AudioObjectPropertyElement] {
        elements.filter { element in
            var address = address(selector, element: element)
            var settable: DarwinBoolean = false
            return AudioObjectHasProperty(id, &address)
                && AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
        }
    }
}

/// An output whose mute and volume tests set by hand; records what the app asked to change.
public final class FakeOutputVolume: SystemOutputControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var state: OutputVolumeState?
    private var changes: [String] = []

    public init(_ state: OutputVolumeState? = OutputVolumeState(deviceName: "Test Speakers", muted: false, volume: 0.5)) {
        self.state = state
    }

    public var current: OutputVolumeState? {
        get { lock.withLock { state } }
        set { lock.withLock { state = newValue } }
    }

    /// "mute:false", "volume:0.50", in order.
    public var log: [String] { lock.withLock { changes } }

    public func read() -> OutputVolumeState? { lock.withLock { state } }

    public func setMuted(_ muted: Bool) throws {
        try lock.withLock {
            guard state != nil else { throw OutputVolumeError.noOutputDevice }
            state?.muted = muted
            changes.append("mute:\(muted)")
        }
    }

    public func setVolume(_ volume: Float) throws {
        try lock.withLock {
            guard state != nil else { throw OutputVolumeError.noOutputDevice }
            state?.volume = volume
            if state?.muted == true { state?.muted = false }
            changes.append(String(format: "volume:%.2f", volume))
        }
    }
}

/// A reply that wasn't spoken because the output was silent.
public struct UnheardReply: Sendable, Hashable {
    public var silence: OutputSilence
    /// Every line of the answer, in order.
    public var text: String
    public var kind: TurnKind

    public init(silence: OutputSilence, text: String, kind: TurnKind) {
        self.silence = silence
        self.text = text
        self.kind = kind
    }
}

extension TurnNotice {
    /// The notch's version of the muted-output notice (no buttons).
    public static func unheard(_ silence: OutputSilence, copied: Bool) -> TurnNotice {
        AudioNotice.unheard(silence, copied: copied, volume: nil).turnNotice
    }
}

extension AudioNotice {
    /// "Your Mac is muted" (or "Your volume is at zero"), saying the reply is on the clipboard, with the fix as a
    /// button. `volume` is the level now: a muted Mac that is also at zero needs the volume raised, not only unmuting.
    public static func unheard(_ silence: OutputSilence, copied: Bool, volume: Float?) -> AudioNotice {
        let where_ = copied ? "I copied my reply to the clipboard." : "My reply is in the text panel."
        switch silence {
        case .muted:
            let alsoZero = (volume ?? 1) <= OutputVolumeState.audibleFloor
            return AudioNotice(kind: .outputMuted, tone: .info, title: "Your Mac is muted, so you didn't hear that.",
                               detail: where_, actions: alsoZero ? [.setVolume(0.5)] : [.unmute], lifetime: 12)
        case .zeroVolume:
            return AudioNotice(kind: .outputZeroVolume, tone: .info, title: "Your volume is at zero, so you didn't hear that.",
                               detail: where_, actions: [.setVolume(0.5)], lifetime: 12)
        }
    }
}

/// Muted-output handling for the voice loop: answers `TurnOutputChecking`, copies an unheard reply to the clipboard and
/// builds the notice, and carries out its Unmute or Set volume button. Only `perform(_:)` changes the system volume.
@MainActor
public final class MutedOutputGuard: TurnOutputChecking {
    public let output: any SystemOutputControlling
    public let pasteboard: any PasteboardAccess
    /// Turn the check off (the user prefers silent answers without notices).
    public var enabled = true
    /// The last reply copied, for tests and logs.
    public private(set) var lastCopied: String?

    public init(output: any SystemOutputControlling = CoreAudioOutputVolume(), pasteboard: any PasteboardAccess = SystemPasteboard()) {
        self.output = output
        self.pasteboard = pasteboard
    }

    public func outputSilence() -> OutputSilence? {
        guard enabled else { return nil }
        return output.read()?.silence
    }

    /// A reply went unheard: copy it and say so. Nil when there was nothing to copy.
    public func replyWasUnheard(_ reply: UnheardReply) -> AudioNotice? {
        let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let copied = pasteboard.writeText(text)
        if copied { lastCopied = text }
        return AudioNotice.unheard(reply.silence, copied: copied, volume: output.read()?.volume)
    }

    /// The user pressed Unmute or Set volume. Returns false for actions that aren't about the output.
    @discardableResult
    public func perform(_ action: AudioNotice.Action) throws -> Bool {
        switch action {
        case .unmute:
            try output.setMuted(false)
            return true
        case .setVolume(let level):
            try output.setVolume(level)
            return true
        default:
            return false
        }
    }
}
