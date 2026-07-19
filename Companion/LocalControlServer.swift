import Darwin
import Foundation
import Shared

struct LocalControlAction: Sendable {
    var response: LocalControlResponse
    var streamSessionID: SessionID?
}

/// User-scoped Unix-domain control socket for the bundled CLI. The socket is
/// mode 0600 and every accepted peer is checked with `getpeereid`.
final class LocalControlServer: @unchecked Sendable {
    typealias Handler = @Sendable (LocalControlRequest) async -> LocalControlAction
    typealias StreamHandler = @Sendable (SessionID, Int32, LocalSocketWriter) async -> Void

    private let socketURL: URL
    private let handler: Handler
    private let streamHandler: StreamHandler
    private let queue = DispatchQueue(label: "com.agentdeck.local-control", qos: .userInitiated)
    private let stateLock = NSLock()
    private var listener: Int32 = -1
    private var running = false
    private var recentRequestIDs: [UUID] = []

    init(
        socketURL: URL = LocalControlPath.socketURL(),
        handler: @escaping Handler,
        streamHandler: @escaping StreamHandler
    ) {
        self.socketURL = socketURL
        self.handler = handler
        self.streamHandler = streamHandler
    }

    deinit { stop() }

    func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !running else { return }
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = unlink(socketURL.path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        do {
            try Self.bind(fd: fd, path: socketURL.path)
            guard listen(fd, 8) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard chmod(socketURL.path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES) }
        } catch {
            close(fd)
            _ = unlink(socketURL.path)
            throw error
        }
        listener = fd
        running = true
        queue.async { [weak self] in self?.acceptLoop(fd: fd) }
    }

    func stop() {
        stateLock.lock()
        let fd = listener
        listener = -1
        running = false
        stateLock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
        _ = unlink(socketURL.path)
    }

    private func acceptLoop(fd: Int32) {
        while isRunning {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.handle(client: client) }
        }
    }

    private var isRunning: Bool {
        stateLock.withLock { running }
    }

    private func handle(client: Int32) {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
            close(client)
            return
        }
        guard let requestData = Self.readLine(fd: client, maximumBytes: LocalControlRequest.maximumEncodedBytes),
              let request = try? JSONDecoder().decode(LocalControlRequest.self, from: requestData),
              request.version == LocalControlRequest.currentVersion,
              remember(request.id) else {
            let response = LocalControlResponse(
                requestID: UUID(), ok: false,
                message: "Invalid, incompatible, oversized, or replayed local request."
            )
            _ = LocalSocketWriter(fd: client).writeJSONLine(response)
            close(client)
            return
        }
        let writer = LocalSocketWriter(fd: client)
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let action = await handler(request)
            guard writer.writeJSONLine(action.response) else {
                close(client); semaphore.signal(); return
            }
            if let sessionID = action.streamSessionID {
                await streamHandler(sessionID, client, writer)
            }
            close(client)
            semaphore.signal()
        }
        semaphore.wait()
    }

    private func remember(_ id: UUID) -> Bool {
        stateLock.withLock {
            guard !recentRequestIDs.contains(id) else { return false }
            recentRequestIDs.append(id)
            if recentRequestIDs.count > 512 { recentRequestIDs.removeFirst(recentRequestIDs.count - 512) }
            return true
        }
    }

    private static func bind(fd: Int32, path: String) throws {
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.withUnsafeBytes { source in buffer.copyBytes(from: source) }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func readLine(fd: Int32, maximumBytes: Int) -> Data? {
        var result = Data()
        var byte: UInt8 = 0
        while result.count < maximumBytes {
            let count = Darwin.recv(fd, &byte, 1, 0)
            guard count == 1 else { return nil }
            if byte == 0x0A { return result }
            result.append(byte)
        }
        return nil
    }
}

final class LocalSocketWriter: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()

    init(fd: Int32) { self.fd = fd }

    func writeJSONLine<T: Encodable>(_ value: T) -> Bool {
        guard var data = try? JSONEncoder().encode(value) else { return false }
        data.append(0x0A)
        return write(data)
    }

    func write(_ data: Data) -> Bool {
        lock.withLock {
            var sent = 0
            return data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return true }
                while sent < data.count {
                    let count = Darwin.send(fd, base.advanced(by: sent), data.count - sent, MSG_NOSIGNAL)
                    if count < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    sent += count
                }
                return true
            }
        }
    }
}
