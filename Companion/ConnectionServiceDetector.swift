import Darwin
import Foundation

/// Detects local overlay-network availability without depending on a
/// particular Tailscale installation channel or requiring daemon IPC.
enum ConnectionServiceDetector {
    static func tailscaleStatus(
        fileManager: FileManager = .default,
        interfaceAddresses: [String]? = nil
    ) -> ConnectionServiceStatus {
        let installed = tailscaleExecutableCandidates.contains {
            fileManager.isExecutableFile(atPath: $0)
        } || fileManager.fileExists(atPath: "/Applications/Tailscale.app")

        let addresses = interfaceAddresses ?? activeIPv4Addresses()
        if addresses.contains(where: isTailscaleIPv4) {
            return .reachable
        }
        return installed ? .unavailable : .notConfigured
    }

    static let tailscaleExecutableCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale"
    ]

    /// Tailscale allocates IPv4 addresses from 100.64.0.0/10.
    static func isTailscaleIPv4(_ address: String) -> Bool {
        var parsed = in_addr()
        guard inet_pton(AF_INET, address, &parsed) == 1 else { return false }
        let hostValue = UInt32(bigEndian: parsed.s_addr)
        return (hostValue & 0xFFC0_0000) == 0x6440_0000
    }

    private static func activeIPv4Addresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }

        var results: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)
            if let address = interface.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) != 0,
               (flags & IFF_RUNNING) != 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    address,
                    socklen_t(address.pointee.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if result == 0 {
                    results.append(host.withUnsafeBufferPointer { buffer in
                        String(cString: buffer.baseAddress!)
                    })
                }
            }
            cursor = interface.ifa_next
        }
        return results
    }
}
