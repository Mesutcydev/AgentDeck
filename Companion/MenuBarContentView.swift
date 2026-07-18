import AppKit
import SwiftUI
import Shared

struct MenuBarContentView: View {
    let state: AppState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                CompanionDeckMark(size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        Text("AGENT").font(.system(size: 17, weight: .black))
                        Text("/DECK").font(.system(size: 17, weight: .black)).foregroundStyle(CompanionDeckColor.signal)
                    }
                    HStack(spacing: 6) {
                        CompanionLiveSignal(
                            color: state.remoteAccessPaused ? CompanionDeckColor.warning : CompanionDeckColor.success,
                            size: 6
                        )
                        .frame(width: 10, height: 10)
                        Text(state.remoteAccessPaused ? "REMOTE ACCESS PAUSED" : listenerStatus)
                            .font(CompanionDeckFont.label)
                            .foregroundStyle(CompanionDeckColor.muted)
                    }
                }
                Spacer()
                Button {
                    Task { await state.refreshStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh status")
            }
            .padding(16)
            .overlay(alignment: .bottom) { Rectangle().fill(CompanionDeckColor.rule).frame(height: 1) }
            .overlay(alignment: .top) { CompanionScanLine() }

            HStack(spacing: 8) {
                CompanionStatusPill(title: "Live", value: "\(state.activeSessionCount)", color: CompanionDeckColor.success)
                CompanionStatusPill(title: "Decisions", value: "\(state.pendingApprovalCount)", color: state.pendingApprovalCount > 0 ? CompanionDeckColor.signal : CompanionDeckColor.muted)
                CompanionStatusPill(title: "Devices", value: "\(state.pairedDeviceCount)", color: CompanionDeckColor.ink)
            }
            .padding(12)

            if !state.recentSessions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    CompanionSectionLabel(index: "01", title: "Recent memory")
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                    ForEach(state.recentSessions.prefix(3), id: \.id) { session in
                        let theme = CompanionProviderTheme.resolve(session.agent)
                        Button {
                            openWindow(id: "sessions")
                        } label: {
                            HStack(spacing: 10) {
                                CompanionProviderMark(agent: session.agent, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(theme.name).font(.system(size: 12, weight: .semibold))
                                    Text(session.state.rawValue.uppercased())
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(CompanionDeckColor.muted)
                                }
                                Spacer()
                                Text(Date(timeIntervalSince1970: Double(session.updatedAt) / 1000), style: .relative)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(CompanionDeckColor.muted)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 42)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .bottom) { Rectangle().fill(CompanionDeckColor.rule).frame(height: 1) }
                    }
                }
                .padding(.bottom, 12)
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        openWindow(id: "sessions")
                    } label: {
                        Label("SESSION MEMORY", systemImage: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CompanionActionStyle(primary: true, tint: CompanionDeckColor.ink))

                    Button {
                        state.openPairingWindow()
                    } label: {
                        Label("PAIR", systemImage: "iphone.gen3")
                    }
                    .buttonStyle(CompanionActionStyle(tint: CompanionDeckColor.signal))
                    .disabled(state.remoteAccessPaused || state.sessionService == nil)
                }

                HStack {
                    Toggle("START AT LOGIN", isOn: loginItemBinding)
                    Spacer()
                    Toggle("PAUSE", isOn: pauseBinding)
                }
                .toggleStyle(.switch)
                .font(CompanionDeckFont.label)
                .tint(CompanionDeckColor.signal)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            HStack(spacing: 14) {
                Button("SETTINGS") { openSettings() }
                Button("DIAGNOSTICS") { Task { await DiagnosticsExporter.export(from: state) } }
                Button("CHECK FOR UPDATES") { state.sparkleController.checkForUpdates() }
                    .disabled(!state.sparkleController.isConfigured)
                Spacer()
                Button("QUIT") { NSApplication.shared.terminate(nil) }
                    .foregroundStyle(CompanionDeckColor.danger)
            }
            .buttonStyle(.plain)
            .font(CompanionDeckFont.label)
            .padding(14)
            .overlay(alignment: .top) { Rectangle().fill(CompanionDeckColor.rule).frame(height: 1) }
        }
        .foregroundStyle(CompanionDeckColor.ink)
        .background(CompanionDeckColor.canvas)
        .frame(width: 390)
        .preferredColorScheme(.light)
        .task { await state.refreshStatus() }
    }

    private var listenerStatus: String {
        state.sessionService?.boundPort.map { "LISTENING · \($0)" } ?? "STARTING"
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { state.loginItemStatus == .enabled },
            set: { enabled in Task { await state.setLoginItemEnabled(enabled) } }
        )
    }

    private var pauseBinding: Binding<Bool> {
        Binding(
            get: { state.remoteAccessPaused },
            set: { paused in Task { await state.setPaused(paused) } }
        )
    }
}
