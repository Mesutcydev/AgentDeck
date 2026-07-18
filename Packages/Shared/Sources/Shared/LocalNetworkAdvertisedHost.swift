//
//  LocalNetworkAdvertisedHost.swift
//  Shared — AgentDeck
//
//  Resolves the host name advertised in pairing QR payloads.
//

import Foundation

public enum LocalNetworkAdvertisedHost {
    /// Host string for QR payloads. Uses the machine's localized name when available.
    public static func current(fallback: String = "127.0.0.1") -> String {
        #if os(macOS)
        if let localized = Host.current().localizedName, !localized.isEmpty {
            return localized
        }
        if let name = Host.current().name, !name.isEmpty {
            return name
        }
        return fallback
        #else
        fallback
        #endif
    }
}
