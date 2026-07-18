import Testing
@testable import Companion

@Suite("Tailscale connection detection")
struct ConnectionServiceDetectorTests {
    @Test("active Tailscale CGNAT address is reachable")
    func activeAddress() {
        #expect(ConnectionServiceDetector.isTailscaleIPv4("100.103.243.4"))
        #expect(!ConnectionServiceDetector.isTailscaleIPv4("192.168.1.5"))
    }

    @Test("addresses outside 100.64/10 are rejected")
    func addressBoundary() {
        #expect(!ConnectionServiceDetector.isTailscaleIPv4("100.63.255.255"))
        #expect(ConnectionServiceDetector.isTailscaleIPv4("100.64.0.1"))
        #expect(ConnectionServiceDetector.isTailscaleIPv4("100.127.255.254"))
        #expect(!ConnectionServiceDetector.isTailscaleIPv4("100.128.0.1"))
    }
}
