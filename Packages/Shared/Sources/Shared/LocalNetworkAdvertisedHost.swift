//
//  LocalNetworkAdvertisedHost.swift
//  Shared — AgentDeck
//
//  Resolves the host name advertised in pairing QR payloads.
//

import Foundation
#if os(macOS)
import Darwin
#endif

public enum LocalNetworkAdvertisedHost {
    /// Host string for QR payloads. A numeric LAN address avoids depending on
    /// mDNS search domains and also avoids advertising a human-facing computer
    /// name containing spaces or punctuation as though it were a DNS name.
    public static func current(fallback: String = "127.0.0.1") -> String {
        #if os(macOS)
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return fallback
        }
        defer { freeifaddrs(interfaces) }

        var candidates: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let socketAddress = interface.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET),
                  (interface.ifa_flags & UInt32(IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == UInt32(IFF_UP | IFF_RUNNING)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let numericHost = host.withUnsafeBufferPointer { buffer in
                String(cString: buffer.baseAddress!)
            }
            candidates.append((String(cString: interface.ifa_name), numericHost))
        }
        return preferredIPv4Address(in: candidates) ?? fallback
        #else
        fallback
        #endif
    }

    /// Address that remains routable when the phone leaves the LAN. If a
    /// Tailscale IPv4 address is active, advertise it; otherwise retain the
    /// ordinary LAN selection. Tailscale's 100.64.0.0/10 address works both
    /// on local Wi-Fi and cellular while the peer VPN is connected.
    public static func remoteAccessCurrent(fallback: String = "127.0.0.1") -> String {
        #if os(macOS)
        let candidates = activeIPv4Candidates()
        return preferredRemoteIPv4Address(in: candidates) ?? fallback
        #else
        fallback
        #endif
    }

    #if os(macOS)
    private static func activeIPv4Candidates() -> [(name: String, address: String)] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        var candidates: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let socketAddress = interface.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET),
                  (interface.ifa_flags & UInt32(IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == UInt32(IFF_UP | IFF_RUNNING)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socketAddress, socklen_t(socketAddress.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            candidates.append((String(cString: interface.ifa_name), address))
        }
        return candidates
    }
    #endif

    static func preferredIPv4Address(in candidates: [(name: String, address: String)]) -> String? {
        candidates
            .filter { !$0.address.hasPrefix("127.") && !$0.address.hasPrefix("169.254.") }
            .sorted { lhs, rhs in
                let left = interfaceRank(lhs.name)
                let right = interfaceRank(rhs.name)
                return left == right ? lhs.name < rhs.name : left < right
            }
            .first?.address
    }

    static func preferredRemoteIPv4Address(in candidates: [(name: String, address: String)]) -> String? {
        candidates.first(where: { isTailscaleIPv4($0.address) })?.address
            ?? preferredIPv4Address(in: candidates)
    }

    private static func interfaceRank(_ name: String) -> Int {
        if name == "en0" { return 0 }
        if name.hasPrefix("en") { return 1 }
        return 2
    }

    static func isTailscaleIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }
}
