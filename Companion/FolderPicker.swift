//
//  FolderPicker.swift
//  Companion — AgentDeck
//
//  Native folder picker seam (§29 Phase 4). Production uses NSOpenPanel;
//  tests inject a fake URL.
//

import AppKit
import Foundation

@MainActor
protocol FolderPicking {
    func pickFolder() -> URL?
}

@MainActor
struct SystemFolderPicker: FolderPicking {
    func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Authorize"
        panel.message = "Choose a project folder AgentDeck may access."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
