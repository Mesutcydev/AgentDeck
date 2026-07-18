//
//  CompanionConfirmationDelegate.swift
//  Companion — AgentDeck
//
//  §13.2 macOS-side pairing phrase confirmation via NSAlert.
//

import AppKit
import Foundation
import Shared

@MainActor
final class CompanionConfirmationDelegate: PairingConfirmationDelegate {
    func confirmPairing(phrase: String, fingerprint: String, peerDisplayName: String) async -> Bool {
        if AppState.isRunningTests { return true }
        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "Confirm pairing with \(peerDisplayName)"
            alert.informativeText = """
            Verify this phrase matches your iPhone:
            \(phrase)

            Fingerprint: \(String(fingerprint.prefix(16)))
            """
            alert.addButton(withTitle: "Confirm")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            continuation.resume(returning: response == .alertFirstButtonReturn)
        }
    }
}
