import Testing
@testable import Shared

@Suite("local-network QR endpoint selection")
struct LocalNetworkAdvertisedHostTests {
    @Test("remote access prefers a Tailscale address over Wi-Fi")
    func remoteAccessPrefersTailscale() {
        let result = LocalNetworkAdvertisedHost.preferredRemoteIPv4Address(in: [
            (name: "en0", address: "192.168.1.5"),
            (name: "utun4", address: "100.103.243.4")
        ])
        #expect(result == "100.103.243.4")
    }

    @Test("Wi-Fi wins over VPN and inactive-style addresses")
    func wifiWins() {
        let result = LocalNetworkAdvertisedHost.preferredIPv4Address(in: [
            ("utun4", "10.8.0.2"),
            ("en0", "192.168.1.5"),
            ("en7", "172.16.0.4")
        ])
        #expect(result == "192.168.1.5")
    }

    @Test("loopback and link-local addresses are never advertised")
    func rejectsUnreachableAddresses() {
        let result = LocalNetworkAdvertisedHost.preferredIPv4Address(in: [
            ("lo0", "127.0.0.1"),
            ("en0", "169.254.21.7")
        ])
        #expect(result == nil)
    }
}
