//
//  SettingsTabView.swift
//  App — AgentDeck
//
//  §17 Settings tab (DESIGN §7.7): system grouped style, token spacing;
//  device identity, connection health, approvals summary, about.
//

import SwiftUI
import Shared

struct SettingsTabView: View {
    @Bindable var state: IOSAppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DeckSpace.xl) {
                    DeckPageHeader(
                        index: "05",
                        title: "Settings",
                        detail: "Identity, connection health, approval policy, and product information."
                    )

                    SettingsLedgerSection(title: "DEVICE") {
                    if let identity = state.identity {
                        SettingsLedgerRow(label: "DEVICE ID", value: identity.shortFingerprint, monospaced: true)
                    } else {
                        SettingsLedgerRow(label: "DEVICE ID", value: "Not loaded")
                    }
                    Text("This iPhone’s pairing identity, shown on your Mac during verification.")
                        .font(DeckFont.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, DeckSpace.xs)
                }

                    SettingsLedgerSection(title: "CONNECTION") {
                    SettingsLedgerRow(label: "STATUS", value: state.remoteConnectionStatus)
                    if state.connectionCircuitOpen {
                        Button {
                            DeckHaptics.retry()
                            Task { await state.retryConnections() }
                        } label: {
                            Label("RECONNECT NOW", systemImage: "arrow.clockwise")
                                .font(DeckFont.monoSmall.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                        }
                        .buttonStyle(DeckActionButtonStyle())
                    }
                    if state.isStoreDegraded {
                        Label("Local store degraded — history kept in memory only.", systemImage: "exclamationmark.triangle")
                            .font(DeckFont.footnote)
                            .foregroundStyle(DeckColor.warning)
                    }
                    if let connectionError = state.error(for: .connection) {
                        Text("\(AppErrorDomain.connection.title.uppercased()) / \(connectionError)")
                            .font(DeckFont.footnote)
                            .foregroundStyle(DeckColor.danger)
                    }
                }

                    SettingsLedgerSection(title: "APPROVALS") {
                    SettingsLedgerRow(label: "PENDING", value: "\(state.pendingApprovalRecords.count)", monospaced: true)
                    SettingsLedgerRow(label: "SAVED RULES", value: "\(state.approvalRules.count)", monospaced: true)
                }

                    SettingsLedgerSection(title: "ABOUT") {
                    SettingsLedgerRow(label: "PRODUCT", value: ProductNaming.name)
                }
                }
                .padding(.horizontal, DeckSpace.m)
                .padding(.bottom, DeckSpace.xl)
            }
            .background { DeckCanvas() }
            .tint(DeckColor.accent)
            .navigationTitle("")
        }
    }
}

private struct SettingsLedgerSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(DeckFont.monoSmall.weight(.semibold))
                .foregroundStyle(DeckColor.accent)
                .padding(.bottom, DeckSpace.xs)
            content
        }
        .overlay(alignment: .top) { Rectangle().fill(DeckColor.rule).frame(height: 0.75) }
        .padding(.top, DeckSpace.s)
    }
}

private struct SettingsLedgerRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DeckSpace.m) {
            Text(label)
                .font(DeckFont.monoSmall)
                .foregroundStyle(.secondary)
            Spacer(minLength: DeckSpace.s)
            Text(value)
                .font(monospaced ? DeckFont.monoSmall : DeckFont.callout)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .textSelection(.enabled)
        }
        .padding(.vertical, DeckSpace.s)
        .overlay(alignment: .bottom) { Rectangle().fill(DeckColor.rule).frame(height: 0.75) }
    }
}
