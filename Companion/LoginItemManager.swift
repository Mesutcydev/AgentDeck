//
//  LoginItemManager.swift
//  Companion — AgentDeck
//
//  §12.2 SMAppService start-at-login, behind a protocol so AppState is
//  unit-testable with a fake. User-level login item only — no admin
//  access anywhere (Constitution #4).
//

import Foundation
import ServiceManagement

public enum LoginItemStatus: String, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    public init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .notFound
        }
    }
}

public protocol LoginItemManaging: Sendable {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() async throws
}

/// The real SMAppService-backed manager (main-app login item).
public struct SystemLoginItemManager: LoginItemManaging {
    public init() {}

    public var status: LoginItemStatus {
        LoginItemStatus(SMAppService.mainApp.status)
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() async throws {
        try await SMAppService.mainApp.unregister()
    }
}
