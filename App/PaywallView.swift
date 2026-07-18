import StoreKit
import SwiftUI

struct PaywallView: View {
    @Bindable var manager: SubscriptionManager
    let launchesUsed: Int
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DeckSpace.xl) {
                    HStack {
                        DeckMark(size: 34, color: DeckColor.ink, showsSignal: true)
                        Text("AGENT/DECK PRO").font(DeckFont.subhead.weight(.black))
                    }
                    ZStack {
                        RoundedRectangle(cornerRadius: 30).fill(DeckColor.ink).frame(height: 190)
                        VStack(spacing: 14) {
                            Image(systemName: "terminal.fill").font(.system(size: 46, weight: .medium)).foregroundStyle(DeckColor.accent)
                                .symbolEffect(.breathe, options: .repeating)
                            Text("YOUR CONTROL PLANE IS READY").font(DeckFont.monoSmall.weight(.bold)).foregroundStyle(DeckColor.canvas)
                            Text("\(launchesUsed) real agent sessions tested").font(DeckFont.footnote).foregroundStyle(DeckColor.canvas.opacity(0.65))
                        }
                    }
                    Text("Keep every agent within reach.").font(DeckFont.display).tracking(-1.1)
                    VStack(alignment: .leading, spacing: DeckSpace.s) {
                        benefit("Unlimited agent and shell launches", "infinity")
                        benefit("Multi-Mac switching and Tailscale access", "desktopcomputer.and.macbook")
                        benefit("Live terminal, session memory, diffs, and approvals", "rectangle.stack.badge.play")
                    }
                    if manager.products.isEmpty && manager.isLoading {
                        ProgressView("Contacting the App Store…").frame(maxWidth: .infinity)
                    } else if manager.products.isEmpty {
                        Button("RETRY APP STORE") { Task { await manager.loadProducts() } }
                            .buttonStyle(DeckActionButtonStyle(primary: true))
                    } else {
                        ForEach(manager.products, id: \.id) { product in
                            Button { Task { await manager.purchase(product) } } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(product.id.contains("annual") ? "ANNUAL PRO" : "MONTHLY PRO").font(DeckFont.monoSmall.weight(.bold))
                                        Text(product.id.contains("annual") ? "Best value · billed annually" : "Flexible monthly access").font(DeckFont.footnote).opacity(0.7)
                                    }
                                    Spacer()
                                    Text(product.displayPrice).font(DeckFont.subhead)
                                }
                                .padding(.horizontal, DeckSpace.m).frame(height: 62)
                            }
                            .buttonStyle(DeckActionButtonStyle(primary: product.id.contains("annual")))
                        }
                    }
                    if let error = manager.errorMessage { Text(error).font(DeckFont.footnote).foregroundStyle(DeckColor.danger) }
                    HStack {
                        Button("Restore Purchases") { Task { await manager.restore() } }
                        Spacer()
                        Link("Manage", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                        Link("Terms", destination: URL(string: "https://mesutcydev.github.io/AgentDeck/terms.html")!)
                        Link("Privacy", destination: URL(string: "https://mesutcydev.github.io/AgentDeck/privacy.html")!)
                    }
                    .font(DeckFont.footnote)
                    Text("Payment is charged to your Apple Account. Auto-renewable subscriptions renew unless canceled at least 24 hours before the current period ends. Manage or cancel in App Store account settings.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(DeckSpace.l)
            }
            .background { DeckCanvas() }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Not Now") { dismiss() } } }
        }
        .interactiveDismissDisabled()
        .onChange(of: manager.isEntitled) { if $1 { dismiss() } }
    }

    private func benefit(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(DeckFont.callout.weight(.semibold))
    }
}
