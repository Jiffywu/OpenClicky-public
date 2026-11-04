import AudioToolbox
import CoreAudio
import Foundation

/// Whether the default output can be heard right now: its mute switch and volume. Read only; OpenClicky never
/// changes either.
public struct OutputSoundState: Sendable, Hashable, Codable {
    public var deviceName: String?
    /// nil when the device has no mute control.
    public var isMuted: Bool?
    /// 0…1, nil when the device has no volume control (HDMI, some interfaces).
    public var volume: Float?

    public init(deviceName: String? = nil, isMuted: Bool? = nil, volume: Float? = nil) {
        self.deviceName = deviceName
        self.isMuted = isMuted
        self.volume = volume
    }

    /// Muted, or the volume all the way down.
    public var isSilent: Bool {
        if isMuted == true { return true }
        if let volume, volume <= 0.001 { return true }
        return false
    }

    public static let audible = OutputSoundState(isMuted: false, volume: 0.5)
    public static let muted = OutputSoundState(isMuted: true, volume: 0.5)
}

public enum OutputSoundProbe {
    /// The default output's mute switch and volume, read from Core Audio. Needs no permission.
    public static func defaultOutput() -> OutputSoundState {
        guard let device = AudioDevices.defaultOutput() else { return OutputSoundState() }
        return OutputSoundState(deviceName: device.name, isMuted: isMuted(device.id), volume: volume(device.id))
    }

    static func isMuted(_ device: AudioDeviceID) -> Bool? {
        // The main element first; some devices only mute per channel, where any muted channel counts.
        if let main = uint32(device, kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain) { return main != 0 }
        let channels = [UInt32(1), 2].compactMap { uint32(device, kAudioDevicePropertyMute, element: $0) }
        return channels.isEmpty ? nil : channels.contains { $0 != 0 }
    }

    static func volume(_ device: AudioDeviceID) -> Float? {
        if let main = float32(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, element: kAudioObjectPropertyElementMain) {
            return main
        }
        let channels = [UInt32(1), 2].compactMap { float32(device, kAudioDevicePropertyVolumeScalar, element: $0) }
        return channels.max()
    }

    private static func uint32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, element: UInt32) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func float32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, element: UInt32) -> Float? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
