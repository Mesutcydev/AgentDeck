import SwiftUI

struct CompanionUserGuidePane: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                guideRow("01", "Authorize a project", "Projects → Add Folder defines where remote agents may run.", "folder.badge.plus")
                arrow
                guideRow("02", "Check providers", "Agents shows actual CLI detection, executable integrity, and versions.", "cpu")
                arrow
                guideRow("03", "Pair the phone", "Open Pair from the menu bar, scan the QR, and compare both verification phrases.", "qrcode")
                arrow
                guideRow("04", "Enable remote reachability", "For cellular access, keep Tailscale active on the Mac and iPhone. The signed handshake migrates the reconnect endpoint.", "network")
                arrow
                guideRow("05", "Review decisions", "AgentDeck never silently grants unrestricted authority. Inspect the exact action and project scope.", "checkmark.shield")
                arrow
                guideRow("06", "Use the terminal bridge", "Run `agentdeck run claude --project /path` to create an attachable session. Control-] detaches without stopping it.", "terminal")
                arrow
                guideRow("07", "Hand off existing work", "Choose Import in the menu bar. Exit the original CLI first, then resume verified Claude or Codex history under AgentDeck.", "arrow.down.to.line.compact")
                GroupBox("User responsibility") {
                    Text("AgentDeck is a control interface, not a guarantee that an agent action is safe. You remain responsible for commands, approvals, credentials, backups, permissions, provider agreements, and applicable compliance requirements.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(CompanionDeckColor.muted)
                }
            }
            .padding(24)
        }
    }

    private func guideRow(_ index: String, _ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(CompanionDeckColor.ink).frame(width: 48, height: 48)
                Image(systemName: symbol).foregroundStyle(CompanionDeckColor.signal)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(index + " / " + title.uppercased()).font(CompanionDeckFont.label).foregroundStyle(CompanionDeckColor.signal)
                Text(detail).font(CompanionDeckFont.body).foregroundStyle(CompanionDeckColor.ink)
            }
        }
    }

    private var arrow: some View {
        Image(systemName: "arrow.down").foregroundStyle(CompanionDeckColor.muted).padding(.leading, 16)
    }
}
