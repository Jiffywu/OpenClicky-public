import Foundation

/// Small POSIX socket helpers for the bridge: a Unix-domain socket between the native host and the app, and a TCP
/// listener bound to 127.0.0.1 for the agent MCP server. Blocking I/O on dedicated threads keeps them simple.
public enum BridgeSocket {
    public enum Error: Swift.Error, CustomStringConvertible {
        case pathTooLong(String)
        case system(String, Int32)
        case alreadyRunning(String)

        public var description: String {
            switch self {
            case .pathTooLong(let path): "socket path is too long for a Unix socket (\(path.utf8.count) bytes): \(path)"
            case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
            case .alreadyRunning(let path): "another OpenClicky bridge is already listening on \(path)"
            }
        }
    }

    private static func unixAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { throw Error.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    private static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Connects to a Unix-domain socket. Returns the descriptor.
    public static func connectUnix(path: String) throws -> Int32 {
        var address = try unixAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.system("socket", errno) }
        noSigPipe(fd)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw Error.system("connect", code)
        }
        return fd
    }

    /// Binds and listens on a Unix-domain socket with mode 0600 (put it in a 0700 folder). A stale socket file left by a crashed process is
    /// replaced; a live one makes this throw `alreadyRunning`.
    public static func listenUnix(path: String) throws -> Int32 {
        var address = try unixAddress(path)
        if FileManager.default.fileExists(atPath: path) {
            if let probe = try? connectUnix(path: path) {
                Darwin.close(probe)
                throw Error.alreadyRunning(path)
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.system("socket", errno) }
        noSigPipe(fd)
        // No umask games here: umask is process-wide and would race other threads creating files. The folder is
        // 0700, so the socket is private from the moment it exists; chmod tightens the file itself right after.
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw Error.system("bind", code)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw Error.system("listen", code)
        }
        return fd
    }

    /// Binds a TCP listener to 127.0.0.1 only. Port 0 picks a free ephemeral port. Returns the descriptor and port.
    public static func listenLoopbackTCP(port: UInt16 = 0) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.system("socket", errno) }
        noSigPipe(fd)
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw Error.system("bind", code)
        }
        guard listen(fd, 64) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw Error.system("listen", code)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, UInt16(bigEndian: actual.sin_port))
    }

    /// The uid of the process on the other end of a Unix-domain socket.
    public static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// Bounds how long a blocking read may wait.
    public static func setReadTimeout(_ fd: Int32, seconds: Double) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Bounds how long a blocking write may wait for a client that stopped reading.
    public static func setWriteTimeout(_ fd: Int32, seconds: Double) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Writes every byte or throws.
    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw Error.system("write", errno)
                }
                offset += written
            }
        }
    }
}

/// Accepts connections on a listening socket without parking a thread in accept(): a dispatch read source fires when
/// connections are pending. `cancel()` stops it and closes the listener (and unlinks a Unix socket path).
public final class SocketAcceptor: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var cancelled = false
    private let closed = DispatchSemaphore(value: 0)

    public init(listener fd: Int32, unlinkOnCancel path: String? = nil, label: String,
                onConnection: @escaping @Sendable (Int32) -> Void) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: label))
        source.setEventHandler {
            while true {
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    return
                }
                // Accepted sockets inherit O_NONBLOCK on Darwin; the bridge uses blocking I/O on its own threads.
                let clientFlags = fcntl(client, F_GETFL)
                _ = fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK)
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                onConnection(client)
            }
        }
        source.setCancelHandler { [closed] in
            Darwin.close(fd)
            if let path { unlink(path) }
            closed.signal()
        }
        source.resume()
    }

    /// Stops accepting. Returns once the listener is closed, so the address can be reused right away.
    public func cancel() {
        let shouldCancel = lock.withLock { () -> Bool in
            defer { cancelled = true }
            return !cancelled
        }
        guard shouldCancel else { return }
        source.cancel()
        _ = closed.wait(timeout: .now() + 2)
    }

    deinit { cancel() }
}
