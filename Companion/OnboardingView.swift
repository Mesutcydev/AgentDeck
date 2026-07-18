import SwiftUI
import Shared

struct OnboardingView: View {
    let state: AppState
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 0) {
                    Text("AGENT").font(.system(size: 42, weight: .black))
                    Text("/DECK").font(.system(size: 42, weight: .black)).foregroundStyle(CompanionDeckColor.signal)
                }
                Text("The authenticated bridge between your Mac agents and every device you trust.")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(CompanionDeckColor.ink.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text("LOCAL ENGINE / REMOTE CONTROL")
                    .font(CompanionDeckFont.label)
                    .foregroundStyle(CompanionDeckColor.signal)
            }
            .padding(36)
            .frame(width: 310)
            .frame(maxHeight: .infinity, alignment: .leading)
            .background(CompanionDeckColor.surface)
            .overlay(alignment: .trailing) { Rectangle().fill(CompanionDeckColor.rule).frame(width: 1) }

            VStack(alignment: .leading, spacing: 24) {
                CompanionPageHeader(
                    index: "00 / START",
                    title: "Your agents stay here.",
                    detail: "AgentDeck streams their real sessions to your phone while this Mac remains the secure execution boundary."
                )
                onboardingRow("01", "Menu bar control", "Connection state, approvals, and recent session memory stay one click away.", "menubar.rectangle")
                onboardingRow("02", "Durable memory", "Session metadata and redacted event history are stored locally in SQLite.", "clock.arrow.circlepath")
                onboardingRow("03", "Explicit trust", "Every new device is paired with a short-lived QR offer and human verification.", "lock.shield")
                Spacer()
                HStack {
                    Text("NO CLOUD EXECUTION · NO SILENT APPROVALS")
                        .font(CompanionDeckFont.label)
                        .foregroundStyle(CompanionDeckColor.muted)
                    Spacer()
                    Button {
                        Task {
                            await state.completeOnboarding()
                            dismissWindow(id: "onboarding")
                        }
                    } label: {
                        HStack { Text("ENTER AGENTDECK"); Image(systemName: "arrow.right") }
                    }
                    .buttonStyle(CompanionActionStyle(primary: true, tint: CompanionDeckColor.signal))
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(36)
        }
        .frame(width: 780, height: 500)
        .background(CompanionDeckColor.canvas)
        .preferredColorScheme(.light)
    }

    private func onboardingRow(_ index: String, _ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(index).font(CompanionDeckFont.label).foregroundStyle(CompanionDeckColor.signal).frame(width: 24)
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(CompanionDeckFont.body).foregroundStyle(CompanionDeckColor.muted)
            }
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(CompanionDeckColor.rule).frame(height: 1) }
    }
}
