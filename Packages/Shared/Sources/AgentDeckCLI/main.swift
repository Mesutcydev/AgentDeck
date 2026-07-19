import Darwin
import Foundation
import Shared

@main
struct AgentDeckCLI {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("agentdeck: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) throws {
        guard let commandText = arguments.first else { printHelp(); return }
        if commandText == "--help" || commandText == "help" { printHelp(); return }
        guard let command = command(for: commandText) else { throw CLIError("Unknown command '\(commandText)'.") }
        let request = try makeRequest(command: command, arguments: Array(arguments.dropFirst()))
        if request.command == .importSession, request.externalSessionID == nil {
            try interactiveImport(projectPath: request.projectPath)
            return
        }
        let socket = try connectStartingCompanionIfNeeded()
        defer { close(socket) }
        let requestData = try JSONEncoder().encode(request)
        guard requestData.count <= LocalControlRequest.maximumEncodedBytes else { throw CLIError("Request is too large.") }
        try writeAll(requestData + Data([0x0A]), to: socket)
        guard let line = readLine(from: socket, maximumBytes: LocalControlRequest.maximumEncodedBytes),
              let response = try? JSONDecoder().decode(LocalControlResponse.self, from: line),
              response.version == LocalControlRequest.currentVersion,
              response.requestID == request.id else { throw CLIError("Companion returned an invalid response.") }
        guard response.ok else { throw CLIError(response.message) }

        switch request.command {
        case .sessions:
            printSessions(response.sessions)
        case .discoverImports:
            printImports(response.imports)
        default:
            print(response.message)
            if let sessionID = response.sessionID { print("session \(sessionID)") }
        }
        if response.streamFollows { try bridgeTerminal(socket: socket) }
    }

    private static func command(for text: String) -> LocalControlCommand? {
        switch text {
        case "status": .status
        case "open": .open
        case "run": .run
        case "sessions": .sessions
        case "attach": .attach
        case "import": .importSession
        case "doctor": .doctor
        default: nil
        }
    }

    private static func makeRequest(command: LocalControlCommand, arguments: [String]) throws -> LocalControlRequest {
        switch command {
        case .run:
            guard let provider = arguments.first else { throw CLIError("Usage: agentdeck run <provider> [--project PATH] [-- provider arguments]") }
            let parsed = parseOptions(Array(arguments.dropFirst()))
            return LocalControlRequest(
                command: .run, provider: provider,
                projectPath: parsed.projectPath ?? FileManager.default.currentDirectoryPath,
                arguments: parsed.trailing
            )
        case .attach:
            guard let id = arguments.first else { throw CLIError("Usage: agentdeck attach <session-id>") }
            return LocalControlRequest(command: .attach, sessionID: id)
        case .importSession:
            let parsed = parseOptions(arguments)
            if parsed.trailing.count >= 2 {
                return LocalControlRequest(
                    command: .importSession, provider: parsed.trailing[0],
                    projectPath: parsed.projectPath ?? FileManager.default.currentDirectoryPath,
                    externalSessionID: parsed.trailing[1]
                )
            }
            return LocalControlRequest(
                command: .importSession,
                projectPath: parsed.projectPath ?? FileManager.default.currentDirectoryPath
            )
        default:
            return LocalControlRequest(command: command)
        }
    }

    private static func interactiveImport(projectPath: String?) throws {
        let discover = LocalControlRequest(command: .discoverImports)
        let socket = try connectStartingCompanionIfNeeded()
        try writeAll(try JSONEncoder().encode(discover) + Data([0x0A]), to: socket)
        guard let line = readLine(from: socket, maximumBytes: LocalControlRequest.maximumEncodedBytes),
              let response = try? JSONDecoder().decode(LocalControlResponse.self, from: line), response.ok else {
            close(socket); throw CLIError("Could not discover provider sessions.")
        }
        close(socket)
        guard !response.imports.isEmpty else { print("No resumable Claude or Codex sessions were found."); return }
        printImports(response.imports)
        print("Select a session number (or q): ", terminator: "")
        guard let input = Swift.readLine(), input != "q", let index = Int(input), response.imports.indices.contains(index - 1) else { return }
        let selected = response.imports[index - 1]
        let importRequest = LocalControlRequest(
            command: .importSession, provider: selected.providerID,
            projectPath: projectPath ?? selected.projectPath ?? FileManager.default.currentDirectoryPath,
            externalSessionID: selected.externalSessionID
        )
        let importSocket = try connectStartingCompanionIfNeeded()
        defer { close(importSocket) }
        try writeAll(try JSONEncoder().encode(importRequest) + Data([0x0A]), to: importSocket)
        guard let importLine = readLine(from: importSocket, maximumBytes: LocalControlRequest.maximumEncodedBytes),
              let imported = try? JSONDecoder().decode(LocalControlResponse.self, from: importLine) else {
            throw CLIError("Invalid import response.")
        }
        guard imported.ok else { throw CLIError(imported.message) }
        print("\(imported.message) · \(imported.sessionID ?? "")")
    }

    private static func parseOptions(_ arguments: [String]) -> (projectPath: String?, trailing: [String]) {
        var project: String?
        var trailing: [String] = []
        var index = 0
        var providerArguments = false
        while index < arguments.count {
            let value = arguments[index]
            if value == "--" { providerArguments = true; index += 1; continue }
            if !providerArguments, value == "--project", index + 1 < arguments.count {
                project = arguments[index + 1]; index += 2; continue
            }
            trailing.append(value); index += 1
        }
        return (project, trailing)
    }

    private static func printSessions(_ sessions: [LocalSessionSummary]) {
        guard !sessions.isEmpty else { print("No sessions."); return }
        for session in sessions {
            print("\(session.id)  \(session.provider)  \(session.state)  \(session.origin)  \(session.projectPath ?? "—")")
        }
    }

    private static func printImports(_ sessions: [ExternalSessionDescriptor]) {
        for (offset, session) in sessions.enumerated() {
            print("\(offset + 1). \(session.providerID)  \(session.externalSessionID)  \(session.processState.rawValue)  \(session.projectPath ?? "unknown project")")
        }
    }

    private static func connectStartingCompanionIfNeeded() throws -> Int32 {
        if let fd = try? connectSocket() { return fd }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "AgentDeck Companion"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        for _ in 0..<50 {
            if let fd = try? connectSocket() { return fd }
            usleep(100_000)
        }
        throw CLIError("Companion is not running. Open AgentDeck Companion and retry.")
    }

    private static func connectSocket() throws -> Int32 {
        let url = LocalControlPath.socketURL()
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK else {
            throw CLIError("Secure Companion socket is unavailable.")
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        guard result == 0 else { let code = errno; close(fd); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .ECONNREFUSED) }
        return fd
    }

    private static func bridgeTerminal(socket: Int32) throws {
        var original = termios()
        let interactive = isatty(STDIN_FILENO) == 1 && tcgetattr(STDIN_FILENO, &original) == 0
        if interactive {
            var raw = original
            cfmakeraw(&raw)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        defer { if interactive { tcsetattr(STDIN_FILENO, TCSANOW, &original) } }
        let output = Thread {
            while let line = readLine(from: socket, maximumBytes: LocalControlRequest.maximumEncodedBytes),
                  let packet = try? JSONDecoder().decode(LocalTerminalMessage.self, from: line),
                  packet.version == LocalControlRequest.currentVersion {
                if packet.kind == .output, let data = packet.data {
                    FileHandle.standardOutput.write(data)
                } else if packet.kind == .error, let message = packet.message {
                    FileHandle.standardError.write(Data("agentdeck: \(message)\n".utf8))
                }
            }
        }
        output.start()

        var size = winsize()
        if ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 {
            try writePacket(
                LocalTerminalMessage(kind: .resize, columns: Int(size.ws_col), rows: Int(size.ws_row)),
                to: socket
            )
        }

        var bytes = [UInt8](repeating: 0, count: 4 * 1024)
        inputLoop: while true {
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            guard count > 0 else { break }
            let data = Data(bytes.prefix(count))
            if let detachIndex = data.firstIndex(of: 0x1D) { // Control-] detaches without terminating.
                let prefix = data.prefix(upTo: detachIndex)
                if !prefix.isEmpty {
                    try writePacket(LocalTerminalMessage(kind: .input, data: Data(prefix)), to: socket)
                }
                break inputLoop
            }
            try writePacket(LocalTerminalMessage(kind: .input, data: data), to: socket)
        }
        try? writePacket(LocalTerminalMessage(kind: .detach), to: socket)
        shutdown(socket, SHUT_WR)
        while !output.isFinished { usleep(10_000) }
    }

    private static func writePacket(_ packet: LocalTerminalMessage, to socket: Int32) throws {
        let encoded = try JSONEncoder().encode(packet)
        guard encoded.count <= LocalControlRequest.maximumEncodedBytes else {
            throw CLIError("Terminal packet is too large.")
        }
        try writeAll(encoded + Data([0x0A]), to: socket)
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        var sent = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while sent < data.count {
                let count = Darwin.send(fd, base.advanced(by: sent), data.count - sent, MSG_NOSIGNAL)
                if count < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                sent += count
            }
        }
    }

    private static func readLine(from fd: Int32, maximumBytes: Int) -> Data? {
        var result = Data(); var byte: UInt8 = 0
        while result.count < maximumBytes {
            guard Darwin.recv(fd, &byte, 1, 0) == 1 else { return nil }
            if byte == 0x0A { return result }
            result.append(byte)
        }
        return nil
    }

    private static func printHelp() {
        print("""
        AgentDeck local agent control

          agentdeck status
          agentdeck open
          agentdeck run <claude|codex|grok|kimi|opencode> [--project PATH] [-- ARGS]
          agentdeck sessions
          agentdeck attach <session-id>       (Control-] detaches)
          agentdeck import [--project PATH] [provider external-session-id]
          agentdeck doctor
        """)
    }
}

private struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
