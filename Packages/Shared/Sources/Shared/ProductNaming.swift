//
//  ProductNaming.swift
//  Shared — AgentDeck
//
//  Single source of the product name (SPEC §2). All user-facing strings,
//  service identifiers, and protocol names derive from `ProductNaming.name`.
//  Never hard-code the literal product name anywhere else.
//

import Foundation

public enum ProductNaming: Sendable {
    /// The committed v1 product name (SPEC §2).
    public static let name = "AgentDeck"

    /// Reverse-DNS log subsystem for all OSLog loggers in the product,
    /// derived from `name` (SPEC §2: service identifiers derive from one source).
    public static let logSubsystem = "com.\(name.lowercased()).diagnostics"

    /// Wire-protocol product token (§9 `type` namespace prefix).
    public static let wireNamespace = name.lowercased()
}
