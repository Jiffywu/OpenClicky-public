import Foundation

/// Chrome native-messaging framing: every message is a 4-byte little-endian length followed by that many bytes of
/// UTF-8 JSON. OpenClicky uses the same framing on the host-to-app Unix socket, so one reader and one writer serve
/// both hops.
public enum NativeMessageFraming {
    /// Chrome refuses host-to-extension messages of 1 MB or more.
    public static let maxToExtension = 1_000_000
    /// Chrome allows extension-to-host messages up to 64 MiB; OpenClicky accepts screenshots up to this size.
    public static let maxFromExtension = 16 * 1024 * 1024

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case tooLarge(Int, limit: Int)
        case notAnObject
        case invalidJSON

        public var description: String {
            switch self {
            case .tooLarge(let size, let limit): "message of \(size) bytes is over the \(limit)-byte limit"
            case .notAnObject: "message is not a JSON object"
            case .invalidJSON: "message is not valid JSON"
            }
        }
    }

    /// The length prefix for a body of `count` bytes.
    public static func header(for count: Int) -> Data {
        var length = UInt32(count).littleEndian
        return withUnsafeBytes(of: &length) { Data($0) }
    }

    /// Reads a 4-byte little-endian length.
    public static func length(of header: Data) -> Int {
        precondition(header.count >= 4)
        let start = header.startIndex
        return Int(header[start]) | Int(header[start + 1]) << 8 | Int(header[start + 2]) << 16 | Int(header[start + 3]) << 24
    }

    /// One framed message for a body that is already JSON.
    public static func frame(_ body: Data, limit: Int = maxFromExtension) throws -> Data {
        guard body.count <= limit else { throw Error.tooLarge(body.count, limit: limit) }
        return header(for: body.count) + body
    }

    public static func frame(_ message: JSONValue, limit: Int = maxFromExtension) throws -> Data {
        try frame(Data(message.jsonString().utf8), limit: limit)
    }

    /// Parses a message body; native messages are always JSON objects.
    public static func decode(_ body: Data) throws -> JSONValue {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: body) else { throw Error.invalidJSON }
        guard case .object = value else { throw Error.notAnObject }
        return value
    }
}

/// Splits a byte stream into framed messages. Feed it whatever arrives, in any chunk sizes; it returns each body as
/// soon as its last byte is in. A length over `limit` throws before any of that body is buffered.
public struct NativeMessageDecoder: Sendable {
    public let limit: Int
    private var buffer = Data()

    public init(limit: Int = NativeMessageFraming.maxFromExtension) { self.limit = limit }

    /// Bytes received but not yet part of a complete message.
    public var pendingByteCount: Int { buffer.count }

    public mutating func feed(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var bodies: [Data] = []
        while buffer.count >= 4 {
            let length = NativeMessageFraming.length(of: buffer.prefix(4))
            guard length <= limit else { throw NativeMessageFraming.Error.tooLarge(length, limit: limit) }
            guard buffer.count >= 4 + length else { break }
            let start = buffer.startIndex + 4
            bodies.append(Data(buffer[start..<start + length]))
            buffer = Data(buffer[(start + length)...])
        }
        return bodies
    }

    /// Like `feed`, parsing each body as a JSON object.
    public mutating func feedMessages(_ chunk: Data) throws -> [JSONValue] {
        try feed(chunk).map(NativeMessageFraming.decode)
    }
}

/// Blocking framed reads and writes on a file descriptor (stdin/stdout for the host, a socket for the bridge).
/// Writes are serialized so several threads can send on one descriptor.
public final class FramedChannel: @unchecked Sendable {
    public let readFD: Int32
    public let writeFD: Int32
    public let readLimit: Int
    public let writeLimit: Int
    private let writeLock = NSLock()
    private let closeLock = NSLock()
    private var decoder: NativeMessageDecoder
    private var queued: [Data] = []
    private var closed = false
    private var released = false
    private let ownsDescriptors: Bool

    public init(readFD: Int32, writeFD: Int32, readLimit: Int = NativeMessageFraming.maxFromExtension,
                writeLimit: Int = NativeMessageFraming.maxFromExtension, ownsDescriptors: Bool = false) {
        self.readFD = readFD
        self.writeFD = writeFD
        self.readLimit = readLimit
        self.writeLimit = writeLimit
        self.decoder = NativeMessageDecoder(limit: readLimit)
        self.ownsDescriptors = ownsDescriptors
    }

    /// A channel over one bidirectional descriptor, such as a connected socket. Closing the channel closes it.
    public convenience init(socket fd: Int32, readLimit: Int = NativeMessageFraming.maxFromExtension,
                            writeLimit: Int = NativeMessageFraming.maxFromExtension) {
        self.init(readFD: fd, writeFD: fd, readLimit: readLimit, writeLimit: writeLimit, ownsDescriptors: true)
    }

    deinit {
        close()
        releaseDescriptors()
    }

    /// The next message body, or nil at end of stream. Throws on oversize or I/O errors. Call from one thread only.
    public func readBody() throws -> Data? {
        while queued.isEmpty {
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
            if count == 0 {
                return nil
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw POSIXError(.ETIMEDOUT) }
                if isClosed { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            queued += try decoder.feed(Data(chunk[0..<count]))
        }
        return queued.removeFirst()
    }

    /// The next message as a JSON object, or nil at end of stream.
    public func read() throws -> JSONValue? {
        guard let body = try readBody() else { return nil }
        return try NativeMessageFraming.decode(body)
    }

    public func write(_ message: JSONValue) throws {
        try writeBody(Data(message.jsonString().utf8))
    }

    public func writeBody(_ body: Data) throws {
        let framed = try NativeMessageFraming.frame(body, limit: writeLimit)
        if isClosed { throw POSIXError(.EPIPE) }
        try writeLock.withLock {
            try framed.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(writeFD, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    offset += written
                }
            }
        }
    }

    public var isClosed: Bool { closeLock.withLock { closed } }

    /// Ends the channel. A socket is shut down at once, which wakes a thread blocked reading it, but its descriptor
    /// is only closed when the channel is freed, so no other thread can ever write into a reused descriptor number.
    /// Pipes (used in tests) are closed at once so the other end sees end-of-file. Unowned descriptors are left alone.
    public func close() {
        let shouldClose = closeLock.withLock { () -> Bool in
            if closed { return false }
            closed = true
            return true
        }
        guard shouldClose, ownsDescriptors else { return }
        var info = stat()
        if fstat(readFD, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK {
            Darwin.shutdown(readFD, SHUT_RDWR)
        } else {
            releaseDescriptors()
        }
    }

    private func releaseDescriptors() {
        let release = closeLock.withLock { () -> Bool in
            if released || !ownsDescriptors { return false }
            released = true
            return true
        }
        guard release else { return }
        Darwin.close(readFD)
        if writeFD != readFD { Darwin.close(writeFD) }
    }
}
