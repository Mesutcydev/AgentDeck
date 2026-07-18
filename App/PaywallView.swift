import StoreKit
import SwiftUI

struct PaywallView: View {
    @Bindable var manager: SubscriptionManager
    let launchesUsed: Int
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var signalOffset: CGFloat = -120

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DeckSpace.xl) {
                    masthead
                    controlPlane

                    VStack(alignment: .leading, spacing: DeckSpace.xs) {
                        Text("KEEP THE DECK RUNNING")
                            .font(DeckFont.monoSmall.weight(.bold))
                            .foregroundStyle(DeckColor.accent)
                        Text("Every agent.\nOne control plane.")
                            .font(DeckFont.display)
                            .tracking(-1.2)
                            .foregroundStyle(DeckColor.ink)
                        Text("You tested \(launchesUsed) real sessions. Pro removes the launch ceiling without hiding the controls you already trust.")
                            .font(DeckFont.body)
                            .foregroundStyle(DeckColor.ink.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    capabilityLedger
                    plans

                    if let error = manager.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(DeckFont.footnote)
                            .foregroundStyle(DeckColor.danger)
                    }

                    footer
                }
                .padding(.horizontal, DeckSpace.l)
                .padding(.bottom, DeckSpace.xxl)
            }
            .background { DeckCanvas() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("NOT NOW", action: dismiss)
                        .font(DeckFont.monoSmall.weight(.semibold))
                        .foregroundStyle(DeckColor.ink.opacity(0.62))
                }
            }
        }
        .interactiveDismissDisabled()
        .onChange(of: manager.isEntitled) { if $1 { DeckHaptics.success(); dismiss() } }
    }

    private var masthead: some View {
        HStack(spacing: DeckSpace.s) {
            DeckMark(size: 32, color: DeckColor.accent, showsSignal: true)
            VStack(alignment: .leading, spacing: 1) {
                Text("AGENT/DECK").font(DeckFont.subhead.weight(.black))
                Text("PRO CONTROL PLANE").font(DeckFont.monoSmall).foregroundStyle(.secondary)
            }
            Spacer()
            Text("UPGRADE / 01")
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(DeckColor.accent)
        }
        .padding(.top, DeckSpace.xs)
    }

    private var controlPlane: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(DeckColor.success).frame(width: 7, height: 7)
                    Text("ALL SYSTEMS READY")
                }
                Spacer()
                Text("05 PROVIDERS")
            }
            .font(.caption2.monospaced().weight(.bold))
            .foregroundStyle(Color.white.opacity(0.72))
            .padding(DeckSpace.m)

            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)

            ZStack {
                HStack(spacing: 0) {
                    providerCell("Claude", AgentThemes.claude.accent)
                    providerCell("Codex", AgentThemes.codex.accent)
                    providerCell("Grok", DeckColor.warning)
                    providerCell("Kimi", AgentThemes.kimi.accent)
                    providerCell("Open", AgentThemes.openCode.accent)
                }
                Rectangle()
                    .fill(DeckColor.accent)
                    .frame(width: 54, height: 2)
                    .shadow(color: DeckColor.accent, radius: 7)
                    .offset(x: signalOffset, y: 31)
            }
            .frame(height: 76)
            .clipped()
        }
        .background(Color(deckHex: 0x111111))
        .clipShape(RoundedRectangle(cornerRadius: DeckRadius.hero, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: DeckRadius.hero).stroke(DeckColor.accent.opacity(0.34)) }
        .task {
            guard !reduceMotion else { signalOffset = 120; return }
            withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) { signalOffset = 180 }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Five coding agent providers ready in one control plane")
    }

    private func providerCell(_ name: String, _ color: Color) -> some View {
        VStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(name.uppercased()).font(.system(size: 8, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(Color.white.opacity(0.74))
        .frame(maxWidth: .infinity)
    }

    private var capabilityLedger: some View {
        VStack(spacing: 0) {
            ledgerRow("01", "UNLIMITED LAUNCHES", "Agent + shell sessions", "infinity")
            ledgerRow("02", "REMOTE CONTROL", "Multi-Mac + Tailnet", "desktopcomputer.and.macbook")
            ledgerRow("03", "SESSION INTELLIGENCE", "Memory, diffs, decisions", "point.3.connected.trianglepath.dotted")
        }
        .deckSurface(accent: DeckColor.accent)
    }

    private func ledgerRow(_ index: String, _ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(spacing: DeckSpace.s) {
            Text(index).font(.caption2.monospaced().weight(.bold)).foregroundStyle(DeckColor.accent)
            Image(systemName: symbol).frame(width: 22).foregroundStyle(DeckColor.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DeckFont.monoSmall.weight(.bold))
                Text(detail).font(DeckFont.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "checkmark").font(.caption.weight(.black)).foregroundStyle(DeckColor.success)
        }
        .padding(.horizontal, DeckSpace.m)
        .frame(minHeight: 62)
        .overlay(alignment: .bottom) { Rectangle().fill(DeckColor.rule).frame(height: 0.5) }
    }

    @ViewBuilder private var plans: some View {
        if manager.products.isEmpty && manager.isLoading {
            HStack { ProgressView(); Text("CONTACTING APP STORE").font(DeckFont.monoSmall); Spacer() }
                .padding(DeckSpace.m).deckSurface(accent: DeckColor.accent)
        } else if manager.products.isEmpty {
            Button("RETRY APP STORE") { Task { await manager.loadProducts() } }
                .buttonStyle(DeckActionButtonStyle(primary: true)).frame(height: 58)
        } else {
            VStack(spacing: DeckSpace.s) {
                ForEach(manager.products, id: \.id) { product in
                    planButton(product)
                }
            }
        }
    }

    private func planButton(_ product: Product) -> some View {
        let annual = product.id.contains("annual")
        return Button {
            DeckHaptics.send()
            Task { await manager.purchase(product) }
        } label: {
            HStack(spacing: DeckSpace.m) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(annual ? "ANNUAL" : "MONTHLY").font(DeckFont.monoSmall.weight(.black))
                        if annual {
                            Text("BEST VALUE").font(.caption2.monospaced().weight(.black))
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(DeckColor.accent).foregroundStyle(DeckColor.canvas)
                        }
                    }
                    Text(annual ? "One year of uninterrupted control" : "Flexible month-to-month access")
                        .font(DeckFont.footnote).opacity(0.62)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(product.displayPrice).font(DeckFont.subhead.weight(.bold))
                    Text(annual ? "/ YEAR" : "/ MONTH").font(.caption2.monospaced())
                }
                Image(systemName: "arrow.up.right").font(.caption.weight(.bold))
            }
            .padding(.horizontal, DeckSpace.m)
            .frame(minHeight: 76)
        }
        .buttonStyle(DeckActionButtonStyle(primary: annual))
        .accessibilityHint("Purchases AgentDeck Pro \(annual ? "annual" : "monthly") subscription")
    }

    private var footer: some View {
        VStack(spacing: DeckSpace.m) {
            HStack {
                Button("RESTORE") { Task { await manager.restore() } }
                Spacer()
                Link("MANAGE", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                Link("TERMS", destination: URL(string: "https://mesutcydev.github.io/AgentDeck/terms.html")!)
                Link("PRIVACY", destination: URL(string: "https://mesutcydev.github.io/AgentDeck/privacy.html")!)
            }
            .font(.caption2.monospaced().weight(.bold))
            .foregroundStyle(DeckColor.ink.opacity(0.62))

            Text("Payment is charged to your Apple Account. Subscriptions renew automatically unless canceled at least 24 hours before the current period ends.")
                .font(.caption2).foregroundStyle(DeckColor.ink.opacity(0.42))
        }
    }
}
