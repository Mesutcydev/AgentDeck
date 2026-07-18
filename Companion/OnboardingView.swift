import SwiftUI
import Shared

struct OnboardingView: View {
    let state: AppState
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var page = 0
    @State private var accepted = false
    @State private var revealed = false

    private let pages: [(String, String, String, String)] = [
        ("01", "The Mac is the boundary", "Your real CLI agents execute here. AgentDeck exposes a controlled, authenticated view—never a cloud copy.", "desktopcomputer"),
        ("02", "Choose the workspace", "Authorize only folders you intend agents to access. Every remote launch inherits that exact project boundary.", "folder.badge.gearshape"),
        ("03", "Pair trusted devices", "Create a short-lived QR offer and compare the verification phrase on both screens before confirming.", "qrcode.viewfinder"),
        ("04", "Stay accountable", "Remote agents can run commands and modify files. Keep backups and approve only actions you understand.", "checkmark.shield")
    ]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                CompanionDeckMark(size: 42)
                    .scaleEffect(revealed ? 1 : 0.72)
                    .opacity(revealed ? 1 : 0)
                HStack(spacing: 0) {
                    Text("AGENT").font(.system(size: 38, weight: .black))
                    Text("/DECK").font(.system(size: 38, weight: .black)).foregroundStyle(CompanionDeckColor.signal)
                }
                Text("LOCAL ENGINE\nREMOTE CONTROL")
                    .font(CompanionDeckFont.label)
                    .foregroundStyle(CompanionDeckColor.muted)
                Spacer()
                TimelineView(.animation(minimumInterval: 0.8)) { context in
                    let live = Int(context.date.timeIntervalSinceReferenceDate) % 2 == 0
                    HStack(spacing: 8) {
                        Circle().fill(CompanionDeckColor.success).frame(width: 7, height: 7)
                            .opacity(live ? 1 : 0.35)
                        Text("SECURE CHANNEL READY").font(CompanionDeckFont.label)
                    }
                }
            }
            .padding(36)
            .frame(width: 286)
            .frame(maxHeight: .infinity, alignment: .leading)
            .background(CompanionDeckColor.surface)
            .overlay(alignment: .trailing) { Rectangle().fill(CompanionDeckColor.rule).frame(width: 1) }

            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("SETUP / \(page + 1) OF \(pages.count)").font(CompanionDeckFont.label).foregroundStyle(CompanionDeckColor.signal)
                    Spacer()
                    Text("GUIDE AVAILABLE IN SETTINGS").font(CompanionDeckFont.label).foregroundStyle(CompanionDeckColor.muted)
                }
                onboardingCard
                    .id(page)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                HStack(spacing: 5) {
                    ForEach(pages.indices, id: \.self) { index in
                        Capsule().fill(index == page ? CompanionDeckColor.signal : CompanionDeckColor.rule)
                            .frame(width: index == page ? 34 : 8, height: 5)
                            .animation(.spring(response: 0.32, dampingFraction: 0.76), value: page)
                    }
                }
                if page == pages.count - 1 {
                    Button { accepted.toggle() } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: accepted ? "checkmark.square.fill" : "square").foregroundStyle(accepted ? CompanionDeckColor.success : CompanionDeckColor.ink)
                            Text("I understand that I am responsible for commands, approvals, credentials, backups, authorized access, and compliance with agent-provider terms.")
                                .font(CompanionDeckFont.body).multilineTextAlignment(.leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                HStack {
                    if page > 0 {
                        Button("BACK") { withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { page -= 1 } }
                            .buttonStyle(CompanionActionStyle())
                    }
                    Spacer()
                    Button {
                        if page < pages.count - 1 {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { page += 1 }
                        } else {
                            Task {
                                await state.completeOnboarding()
                                dismissWindow(id: "onboarding")
                            }
                        }
                    } label: {
                        HStack { Text(page == pages.count - 1 ? "ACCEPT & START" : "CONTINUE"); Image(systemName: "arrow.right") }
                    }
                    .buttonStyle(CompanionActionStyle(primary: true, tint: CompanionDeckColor.signal))
                    .disabled(page == pages.count - 1 && !accepted)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(36)
        }
        .frame(width: 820, height: 540)
        .background(CompanionDeckColor.canvas)
        .preferredColorScheme(.light)
        .onAppear { withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) { revealed = true } }
    }

    private var onboardingCard: some View {
        let item = pages[page]
        return HStack(alignment: .top, spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(CompanionDeckColor.ink).frame(width: 92, height: 92)
                Image(systemName: item.3).font(.system(size: 32, weight: .semibold)).foregroundStyle(CompanionDeckColor.signal)
                    .symbolEffect(.breathe, options: .repeating)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(item.0 + " / CONTROL PLANE").font(CompanionDeckFont.label).foregroundStyle(CompanionDeckColor.signal)
                Text(item.1).font(.system(size: 28, weight: .black))
                Text(item.2).font(.system(size: 15)).foregroundStyle(CompanionDeckColor.muted).fixedSize(horizontal: false, vertical: true)
                if page == 2 {
                    Label("After setup, open Settings → User Guide for the full visual walkthrough.", systemImage: "book.pages")
                        .font(CompanionDeckFont.body.weight(.semibold)).padding(10).background(CompanionDeckColor.surface)
                }
            }
        }
        .padding(.vertical, 16)
    }
}
