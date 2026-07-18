//
//  TerminalEngineView.swift
//  App — AgentDeck
//
//  §29 Phase 5 SwiftTerm host wrapped for SwiftUI.
//

import SwiftUI
import SwiftTerm
import Shared
import UIKit
import UniformTypeIdentifiers

struct TerminalEngineView: UIViewRepresentable {
    var model: TerminalSessionModel
    var theme: AgentTheme = AgentThemes.generic

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        // §3/§7.4: the terminal surface takes the agent theme's native
        // colors so each wrapper resembles its own product's terminal.
        view.nativeBackgroundColor = UIColor(theme.terminalBackground)
        view.nativeForegroundColor = UIColor(theme.terminalText)
        view.inputAccessoryView = TerminalKeyboardAccessoryView(
            onControl: { context.coordinator.sendControl() },
            onEscape: { context.coordinator.sendEscape() },
            onPaste: { context.coordinator.pasteFromClipboard() }
        )
        model.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        uiView.isUserInteractionEnabled = model.interactionMode == .interactive
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let model: TerminalSessionModel

        init(model: TerminalSessionModel) {
            self.model = model
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            model.sendInput(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            model.resize(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}

        /// Selection copy from SwiftTerm: place the raw bytes on the system
        /// pasteboard as plain text.
        func clipboardCopy(source: TerminalView, content: Data) {
            UIPasteboard.general.setData(content, forPasteboardType: UTType.plainText.identifier)
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func sendControl() {
            model.sendInput(Data([0x01]))
        }

        func sendEscape() {
            model.sendInput(Data([0x1b]))
        }

        /// Paste action: clipboard text becomes terminal input (sent as a
        /// `terminal.input` frame by the model's onInput wiring).
        func pasteFromClipboard() {
            guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
            model.sendInput(Data(text.utf8))
        }
    }
}
