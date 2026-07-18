//
//  RawOutputView.swift
//  App — AgentDeck
//
//  §10.4 read-only degraded terminal output surface.
//

import SwiftUI

struct RawOutputView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "No raw output yet." : text)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .background(Color(uiColor: .systemBackground))
    }
}
