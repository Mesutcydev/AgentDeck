import SwiftUI

struct IOSOnboardingView: View {
    let complete: () -> Void
    @State private var page = 0
    @State private var accepted = false
    @State private var appeared = false

    private let pages: [(String, String, String, String)] = [
        ("01", "Your agents. Your Mac.", "AgentDeck is a secure visual remote for CLI agents that continue running on computers you control.", "terminal.fill"),
        ("02", "Pair the boundary", "Scan the Companion QR, verify the phrase on both devices, then choose the active Mac from Home.", "lock.shield.fill"),
        ("03", "Work conversationally", "Start Claude, Codex, Grok, Kimi, or OpenCode with one tap. Stream output, send prompts, and review exact approvals.", "bubble.left.and.text.bubble.right.fill"),
        ("04", "You remain in control", "Agents can modify files and run commands. Review scopes, keep backups, and approve only actions you understand.", "checkmark.shield.fill")
    ]

    var body: some View {
        ZStack {
            DeckColor.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    DeckMark(size: 30, color: DeckColor.ink, showsSignal: true)
                    Text("AGENT/DECK").font(DeckFont.subhead.weight(.black))
                    Spacer()
                    Text("SETUP  \(page + 1)/\(pages.count)")
                        .font(DeckFont.monoSmall.weight(.semibold))
                        .foregroundStyle(DeckColor.accent)
                }
                .padding(.horizontal, DeckSpace.l)
                .padding(.top, DeckSpace.m)

                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { index in
                        onboardingPage(index).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                VStack(spacing: DeckSpace.s) {
                    HStack(spacing: 6) {
                        ForEach(pages.indices, id: \.self) { index in
                            Capsule()
                                .fill(index == page ? DeckColor.accent : DeckColor.rule)
                                .frame(width: index == page ? 30 : 8, height: 5)
                                .animation(DeckMotion.quick, value: page)
                        }
                    }
                    if page == pages.count - 1 {
                        Button { accepted.toggle(); DeckHaptics.light() } label: {
                            HStack(alignment: .top, spacing: DeckSpace.s) {
                                Image(systemName: accepted ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(accepted ? DeckColor.success : DeckColor.ink)
                                Text("I understand that AgentDeck controls tools on my computers. I am responsible for commands, approvals, credentials, backups, and compliance with provider terms.")
                                    .font(DeckFont.footnote)
                                    .foregroundStyle(DeckColor.ink)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        if page < pages.count - 1 {
                            withAnimation(DeckMotion.standard) { page += 1 }
                            DeckHaptics.light()
                        } else if accepted {
                            DeckHaptics.success()
                            complete()
                        }
                    } label: {
                        HStack {
                            Text(page == pages.count - 1 ? "ACCEPT & ENTER" : "CONTINUE")
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .font(DeckFont.monoSmall.weight(.bold))
                        .padding(.horizontal, DeckSpace.m)
                        .frame(height: 52)
                    }
                    .buttonStyle(DeckActionButtonStyle(primary: true))
                    .disabled(page == pages.count - 1 && !accepted)
                }
                .padding(DeckSpace.l)
            }
        }
        .onAppear { withAnimation(.spring(response: 0.8, dampingFraction: 0.72)) { appeared = true } }
        .interactiveDismissDisabled()
    }

    private func onboardingPage(_ index: Int) -> some View {
        let item = pages[index]
        return VStack(alignment: .leading, spacing: DeckSpace.xl) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .stroke(DeckColor.rule, lineWidth: 1)
                    .frame(width: 190, height: 190)
                    .rotationEffect(.degrees(appeared ? 0 : -12))
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(DeckColor.ink)
                    .frame(width: 138, height: 138)
                Image(systemName: item.3)
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(DeckColor.accent)
                    .symbolEffect(.breathe, options: .repeating)
            }
            .frame(maxWidth: .infinity)
            Text(item.0 + " / FIELD GUIDE").font(DeckFont.monoSmall.weight(.semibold)).foregroundStyle(DeckColor.accent)
            Text(item.1).font(DeckFont.display).tracking(-1.2)
            Text(item.2).font(DeckFont.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if index == 2 {
                Label("A visual How to Use guide is always available in Settings.", systemImage: "book.pages")
                    .font(DeckFont.footnote.weight(.semibold))
                    .padding(DeckSpace.s)
                    .background(DeckColor.surfaceRaised)
            }
            Spacer()
        }
        .padding(.horizontal, DeckSpace.l)
    }
}

struct IOSUserGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DeckSpace.xl) {
                DeckPageHeader(index: "GUIDE / 01", title: "How to use AgentDeck", detail: "From pairing to a controlled agent conversation.")
                guideStep("01", "Run Companion", "Install AgentDeck Companion on each Mac. Confirm LISTENING and Tailscale REACHABLE for remote use.", "desktopcomputer")
                connector
                guideStep("02", "Pair and select", "Scan its QR from Macs. On Home, use the Mac switcher to choose where new work starts.", "qrcode.viewfinder")
                connector
                guideStep("03", "Start an agent", "Tap a detected provider. AgentDeck launches its real CLI inside the selected project—no command typing needed.", "play.fill")
                connector
                guideStep("04", "Chat, inspect, approve", "Activity is the conversation; Console is the exact PTY; Output is readable text; Changes shows the working diff.", "bubble.left.and.text.bubble.right")
                connector
                guideStep("05", "Stop or retain", "Swipe a live conversation to stop it. Completed sessions remain in Session Memory until you delete them.", "clock.arrow.circlepath")
                DisclosureGroup("Safety and user agreement") {
                    Text("AgentDeck does not make agent actions safe by itself. You are responsible for reviewing commands and approvals, protecting credentials, maintaining backups, respecting software/provider terms, and complying with applicable rules. Remote access depends on your network configuration. Never approve an action you do not understand.")
                        .font(DeckFont.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, DeckSpace.s)
                }
                .font(DeckFont.callout.weight(.semibold))
                .padding(DeckSpace.m)
                .background(DeckColor.surfaceRaised)
            }
            .padding(DeckSpace.m)
        }
        .background { DeckCanvas() }
        .navigationTitle("User Guide")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func guideStep(_ index: String, _ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: DeckSpace.m) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(DeckColor.ink).frame(width: 52, height: 52)
                Image(systemName: symbol).foregroundStyle(DeckColor.accent).font(.system(size: 20, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(index + " / " + title.uppercased()).font(DeckFont.monoSmall.weight(.bold)).foregroundStyle(DeckColor.accent)
                Text(detail).font(DeckFont.callout).foregroundStyle(DeckColor.ink)
            }
        }
    }

    private var connector: some View {
        Rectangle().fill(DeckColor.rule).frame(width: 2, height: 22).padding(.leading, 25)
    }
}
