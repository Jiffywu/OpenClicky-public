import CoreAudio
import Foundation

/// How an audio device is connected. Bluetooth matters most: opening a Bluetooth microphone flips the headset into
/// its low-quality call profile, so capture holds it open between presses.
public enum AudioDeviceTransport: Sendable, Hashable, CustomStringConvertible {
    case builtIn, usb, bluetooth, bluetoothLE, hdmi, displayPort, airPlay, thunderbolt, pci, fireWire
    case aggregate, virtual, continuity, unknown(UInt32)

    init(code: UInt32) {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeBluetooth: self = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypePCI: self = .pci
        case kAudioDeviceTransportTypeFireWire: self = .fireWire
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: self = .aggregate
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: self = .continuity
        default: self = .unknown(code)
        }
    }

    public var isBluetooth: Bool { self == .bluetooth || self == .bluetoothLE }

    public var description: String {
        switch self {
        case .builtIn: "built-in"
        case .usb: "USB"
        case .bluetooth: "Bluetooth"
        case .bluetoothLE: "Bluetooth LE"
        case .hdmi: "HDMI"
        case .displayPort: "DisplayPort"
        case .airPlay: "AirPlay"
        case .thunderbolt: "Thunderbolt"
        case .pci: "PCI"
        case .fireWire: "FireWire"
        case .aggregate: "aggregate"
        case .virtual: "virtual"
        case .continuity: "Continuity"
        case .unknown(let code): "unknown(\(code))"
        }
    }
}

public struct AudioDeviceInfo: Sendable, Hashable, Identifiable {
    public var id: AudioDeviceID
    /// Stable across reboots and reconnects; what settings store.
    public var uid: String
    public var name: String
    public var transport: AudioDeviceTransport
    public var inputChannels: Int
    public var outputChannels: Int
    public var nominalSampleRate: Double
    public var isDefaultInput: Bool
    public var isDefaultOutput: Bool

    public init(id: AudioDeviceID, uid: String, name: String, transport: AudioDeviceTransport, inputChannels: Int, outputChannels: Int,
                nominalSampleRate: Double, isDefaultInput: Bool, isDefaultOutput: Bool) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.nominalSampleRate = nominalSampleRate
        self.isDefaultInput = isDefaultInput
        self.isDefaultOutput = isDefaultOutput
    }
}

/// Read-only CoreAudio queries. Listing devices needs no permission.
public enum AudioDevices {
    public static func all() -> [AudioDeviceInfo] {
        let defaultIn = defaultDeviceID(input: true)
        let defaultOut = defaultDeviceID(input: false)
        return deviceIDs().compactMap { info($0, defaultInput: defaultIn, defaultOutput: defaultOut) }
    }

    public static func inputs() -> [AudioDeviceInfo] { all().filter { $0.inputChannels > 0 } }
    public static func outputs() -> [AudioDeviceInfo] { all().filter { $0.outputChannels > 0 } }

    public static func defaultInput() -> AudioDeviceInfo? {
        defaultDeviceID(input: true).flatMap { info($0) }
    }

    public static func defaultOutput() -> AudioDeviceInfo? {
        defaultDeviceID(input: false).flatMap { info($0) }
    }

    public static func device(uid: String) -> AudioDeviceInfo? {
        all().first { $0.uid == uid }
    }

    /// The Mac's own microphone, the failover target when a selected mic goes dead.
    public static func builtInInput() -> AudioDeviceInfo? {
        inputs().first { $0.transport == .builtIn }
    }

    public static func info(_ id: AudioDeviceID, defaultInput: AudioDeviceID? = nil, defaultOutput: AudioDeviceID? = nil) -> AudioDeviceInfo? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let defaultIn = defaultInput ?? defaultDeviceID(input: true)
        let defaultOut = defaultOutput ?? defaultDeviceID(input: false)
        return AudioDeviceInfo(
            id: id,
            uid: uid,
            name: string(id, kAudioObjectPropertyName) ?? uid,
            transport: AudioDeviceTransport(code: scalar(id, kAudioDevicePropertyTransportType, default: UInt32(0))),
            inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
            outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
            nominalSampleRate: scalar(id, kAudioDevicePropertyNominalSampleRate, default: Float64(0)),
            isDefaultInput: id == defaultIn,
            isDefaultOutput: id == defaultOut
        )
    }

    // MARK: CoreAudio plumbing

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultDeviceID(input: Bool) -> AudioDeviceID? {
        let selector = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        let id: AudioDeviceID = scalar(AudioObjectID(kAudioObjectSystemObject), selector, default: AudioDeviceID(kAudioObjectUnknown))
        return id == kAudioObjectUnknown ? nil : id
    }

    static func deviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, raw.baseAddress!)
        }
        return status == noErr ? ids : []
    }

    static func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, default fallback: T) -> T {
        var address = address(selector)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? value : fallback
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Calls back (on `queue`) when the default input or output device changes or devices come and go.
public final class AudioDeviceWatcher: @unchecked Sendable {
    public enum Change: Sendable, Hashable { case defaultInput, defaultOutput, deviceList }

    private let queue: DispatchQueue
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    public init(queue: DispatchQueue, onChange: @escaping @Sendable (Change) -> Void) {
        self.queue = queue
        let watched: [(AudioObjectPropertySelector, Change)] = [
            (kAudioHardwarePropertyDefaultInputDevice, .defaultInput),
            (kAudioHardwarePropertyDefaultOutputDevice, .defaultOutput),
            (kAudioHardwarePropertyDevices, .deviceList),
        ]
        for (selector, change) in watched {
            var address = AudioDevices.address(selector)
            let block: AudioObjectPropertyListenerBlock = { _, _ in onChange(change) }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr {
                listeners.append((address, block))
            }
        }
    }

    deinit {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
    }
}
