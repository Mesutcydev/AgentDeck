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
                    NavigationLink {
                        IOSUserGuideView()
                    } label: {
                        HStack {
                            Label("HOW TO USE AGENTDECK", systemImage: "book.pages")
                                .font(DeckFont.monoSmall.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(DeckColor.ink)
                        .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                    SettingsLedgerRow(label: "PRODUCT", value: ProductNaming.name)
                    SettingsLedgerRow(
                        label: "PLAN",
                        value: BuildChannel.isDebugUnlocked
                            ? "Unlocked · \(BuildChannel.label)"
                            : (state.subscription.isEntitled ? "Pro" : "Free · \(state.freeLaunchesRemaining) launches left")
                    )
                    Button("RESTORE PURCHASES") { Task { await state.subscription.restore() } }
                        .font(DeckFont.monoSmall.weight(.semibold))
                        .frame(height: 40)
                }

                if BuildChannel.isDebugUnlocked {
                    SettingsLedgerSection(title: "DEBUGGER") {
                        NavigationLink {
                            DebugConsoleView(state: state)
                        } label: {
                            HStack {
                                Label("OPEN EVENT CONSOLE", systemImage: "ladybug")
                                    .font(DeckFont.monoSmall.weight(.semibold))
                                Spacer()
                                Text("\(state.debugEntries.count)")
                                    .font(DeckFont.monoSmall)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(DeckColor.ink)
                            .frame(height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                    }
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

private struct DebugConsoleView: View {
    @Bindable var state: IOSAppState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if state.debugEntries.isEmpty {
                        DeckEmptyLedger(
                            index: "00",
                            title: "Awaiting events",
                            detail: "Connection, provider launch, prompt, and terminal failures appear here. Prompt contents are never recorded.",
                            systemImage: "ladybug",
                            accent: DeckColor.accent
                        )
                    } else {
                        ForEach(state.debugEntries) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(entry.category)
                                        .foregroundStyle(DeckColor.accent)
                                    Spacer()
                                    Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                        .foregroundStyle(.secondary)
                                }
                                .font(DeckFont.monoSmall)
                                Text(entry.message)
                                    .font(DeckFont.monoSmall)
                                    .foregroundStyle(DeckColor.ink)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, DeckSpace.s)
                            .overlay(alignment: .bottom) { Rectangle().fill(DeckColor.rule).frame(height: 0.75) }
                            .id(entry.id)
                        }
                    }
                }
                .padding(.horizontal, DeckSpace.m)
            }
            .background { DeckCanvas() }
            .onChange(of: state.debugEntries.count) {
                if let last = state.debugEntries.last?.id {
                    withAnimation(DeckMotion.quick) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .navigationTitle("Event Console")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") { state.clearDebugEntries() }
            }
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
