import Foundation

/// Compile-time distribution channel. TestFlight archives must use the
/// `App-TestFlight` scheme; App Store archives use `App` (Release).
enum BuildChannel {
    #if DEBUG
    static let isDebugUnlocked = true
    static let label = "Developer Debug"
    #elseif TESTFLIGHT_INTERNAL
    static let isDebugUnlocked = true
    static let label = "TestFlight Internal"
    #else
    static let isDebugUnlocked = false
    static let label = "App Store"
    #endif
}
