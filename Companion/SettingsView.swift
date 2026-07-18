//
//  SettingsView.swift
//  Companion — AgentDeck
//
//  Native Settings scene with every §12.7 section: General, Paired
//  Devices, Projects, Agents, Connections, Permission Policies,
//  Notifications, Security, Diagnostics, About. Panes not owned by this
//  phase are honest scaffolds — real wiring lands in later phases.
//

import SwiftUI
import Shared

struct SettingsView: View {
    let state: AppState
    @State private var selection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    CompanionDeckMark(size: 25)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("AGENT/DECK").font(.system(size: 14, weight: .black))
                        Text("CONTROL PLANE").font(.caption2.monospaced()).foregroundStyle(CompanionDeckColor.muted)
                    }
                    Spacer()
                }
                .padding(16)
                .overlay(alignment: .bottom) { Rectangle().fill(CompanionDeckColor.rule).frame(height: 1) }

                List(SettingsSection.allCases) { section in
                    Button {
                        selection = section
                    } label: {
                        Label(section.title, systemImage: section.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(
                        selection == section ? Color.accentColor : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .foregroundStyle(selection == section ? Color.white : CompanionDeckColor.ink)
                    .contentShape(Rectangle())
                    .listRowInsets(.init(top: 1, leading: 8, bottom: 1, trailing: 8))
                    .listRowBackground(Color.clear)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .background(CompanionDeckColor.surface)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                CompanionPageHeader(index: selection.index, title: selection.title, detail: selection.detail)
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                selectedPane
            }
            .background(CompanionDeckColor.canvas)
        }
        .toolbar(removing: .sidebarToggle)
        .frame(width: 820, height: 560)
        .foregroundStyle(CompanionDeckColor.ink)
        .tint(CompanionDeckColor.signal)
        .preferredColorScheme(.light)
    }

    @ViewBuilder private var selectedPane: some View {
        switch selection {
        case .general: GeneralSettingsPane(state: state)
        case .devices: PairedDevicesPane(state: state)
        case .projects: ProjectsPane(state: state)
        case .agents: AgentsPane(state: state)
        case .connections: ConnectionsPane(state: state)
        case .permissions: PermissionPoliciesPane(state: state)
        case .notifications: NotificationsPane(state: state)
        case .security: SecurityPane()
        case .diagnostics: DiagnosticsSettingsPane(state: state)
        case .guide: CompanionUserGuidePane()
        case .about: AboutPane()
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, devices, projects, agents, connections, permissions, notifications, security, diagnostics, guide, about
    var id: String { rawValue }
    var title: String { switch self {
        case .general: "General"; case .devices: "Paired Devices"; case .projects: "Projects"; case .agents: "Agents"; case .connections: "Connections"; case .permissions: "Permission Policies"; case .notifications: "Notifications"; case .security: "Security"; case .diagnostics: "Diagnostics"; case .guide: "User Guide"; case .about: "About"
    } }
    var symbol: String { switch self {
        case .general: "gear"; case .devices: "iphone"; case .projects: "folder"; case .agents: "cpu"; case .connections: "network"; case .permissions: "checkmark.shield"; case .notifications: "bell"; case .security: "lock.shield"; case .diagnostics: "stethoscope"; case .guide: "book.pages"; case .about: "info.circle"
    } }
    var index: String { String(format: "%02d / SETTINGS", (Self.allCases.firstIndex(of: self) ?? 0) + 1) }
    var detail: String { switch self {
        case .general: "Choose startup and remote-access behavior."; case .devices: "Manage authenticated phones and tablets."; case .projects: "Control exactly which folders agents may access."; case .agents: "Inspect real CLI discovery and installation state."; case .connections: "Review active local and remote transport paths."; case .permissions: "Understand the trust scopes enforced on this Mac."; case .notifications: "Configure redacted background approval alerts."; case .security: "Inspect local key and authentication boundaries."; case .diagnostics: "Export a redacted operational report."; case .guide: "Learn the complete pairing and agent-control workflow."; case .about: "Build identity and product role."
    } }
}

private struct GeneralSettingsPane: View {
    let state: AppState

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Start at Login", isOn: Binding(
                    get: { state.loginItemStatus == .enabled },
                    set: { enabled in Task { await state.setLoginItemEnabled(enabled) } }
                ))
                if state.loginItemStatus == .requiresApproval {
                    Text("macOS requires approval: enable AgentDeck in System Settings → General → Login Items.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Remote Access") {
                Toggle("Pause Remote Access", isOn: Binding(
                    get: { state.remoteAccessPaused },
                    set: { paused in Task { await state.setPaused(paused) } }
                ))
                Text("Pause rejects new connections; local agent sessions keep running.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PairedDevicesPane: View {
    let state: AppState

    var body: some View {
        Form {
            Section("Devices") {
                if state.pairedDevices.isEmpty {
                    Text("No paired devices yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.pairedDevices, id: \.id) { device in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.displayName).font(.headline)
                            Text(device.id.wireString)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            if let lastSeen = device.lastSeenAt {
                                Text("Last seen: \(Date(timeIntervalSince1970: TimeInterval(lastSeen) / 1000), format: .relative(presentation: .named))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button("Revoke Device", role: .destructive) {
                                Task { await state.revokePairedDevice(device) }
                            }
                        }
                    }
                }
                Button("Pair New Device…") {
                    state.openPairingWindow()
                }
                .disabled(state.remoteAccessPaused || state.sessionService == nil)
            }
            if let port = state.sessionService?.boundPort {
                Section("Listener") {
                    LabeledContent("Port", value: "\(port)")
                }
            }
            if let error = state.sessionService?.lastError {
                Section {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .task { await state.refreshStatus() }
    }
}

private struct ProjectsPane: View {
    let state: AppState

    var body: some View {
        Form {
            Section("Authorized Projects") {
                if let workspace = state.projectWorkspace {
                    if workspace.projects.isEmpty {
                        Text("No authorized projects yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(workspace.projects, id: \.id) { project in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.displayName).font(.headline)
                                Text(project.canonicalPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    if project.isGitRepository {
                                        Text(project.branch ?? "detached")
                                            .font(.caption2)
                                    } else {
                                        Text("non-git")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    if project.isFavorite {
                                        Text("favorite")
                                            .font(.caption2)
                                    }
                                    if project.isWorktree {
                                        Text("worktree")
                                            .font(.caption2)
                                    }
                                }
                            }
                            .contextMenu {
                                Button(project.isFavorite ? "Remove Favorite" : "Add Favorite") {
                                    Task { await workspace.toggleFavorite(project) }
                                }
                                Button("Reauthorize…") {
                                    Task { await workspace.reauthorizeProject(project) }
                                }
                                Button("Remove Authorization", role: .destructive) {
                                    Task { await workspace.removeProject(project) }
                                }
                            }
                        }
                    }
                    Button("Authorize Folder…") {
                        Task { await workspace.authorizeNewProject() }
                    }
                } else {
                    Text("Session store unavailable.")
                        .foregroundStyle(.secondary)
                }
            }
            if let error = state.projectWorkspace?.lastError {
                Section {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AgentsPane: View {
    let state: AppState

    var body: some View {
        Form {
            Section("Installed Agents") {
                if let workspace = state.projectWorkspace {
                    if workspace.discoveredAgents.isEmpty {
                        Text("No agents discovered yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(workspace.discoveredAgents, id: \.id) { agent in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(agent.descriptor.displayName).font(.headline)
                                switch agent.installation.state {
                                case .installed(let version):
                                    Text(version).font(.caption).foregroundStyle(.secondary)
                                    if let path = agent.installation.executablePath {
                                        Text(path).font(.caption2).foregroundStyle(.secondary)
                                    }
                                case .notInstalled:
                                    Text("Not installed").font(.caption).foregroundStyle(.secondary)
                                case .broken(let reason):
                                    Text(reason).font(.caption).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    Button("Refresh Detection") {
                        Task { await workspace.refresh() }
                    }
                } else {
                    Text("Session store unavailable.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ConnectionsPane: View {
    let state: AppState

    var body: some View {
        Form {
            Section("Connection Methods") {
                LabeledContent("Tailscale", value: state.tailscaleStatus.menuDescription)
                LabeledContent("Local network", value: state.sessionService?.boundPort.map { "Listening on port \($0)" } ?? "Unavailable")
                LabeledContent("Cloudflare Tunnel", value: state.cloudflareStatus.menuDescription)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionPoliciesPane: View {
    let state: AppState

    var body: some View {
        Form {
            Section("Rules") {
                if state.approvalRules.isEmpty {
                    Text("No active approval rules.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.approvalRules) { rule in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.displayText).font(.headline)
                            HStack {
                                Text(rule.choice.rawValue.uppercased())
                                if let tool = rule.tool { Text("· \(tool)") }
                                if let pattern = rule.commandPattern { Text("· \(pattern)").lineLimit(1) }
                            }
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button("Revoke Rule", role: .destructive) {
                                Task { await state.revokeApprovalRule(rule) }
                            }
                        }
                    }
                }
                Text("Rules are created only from explicit approval decisions. Unrestricted always-approve is not representable.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Critical Actions") {
                Text("Critical approvals require in-app secure confirmation and device authentication.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await state.refreshStatus() }
    }
}

private struct NotificationsPane: View {
    let state: AppState
    @State private var relayURLText = ""
    @State private var validationMessage: String?

    var body: some View {
        Form {
            Section("Background Alerts") {
                LabeledContent("Notification relay", value: state.relayBaseURL?.absoluteString ?? "Not configured")
                TextField("https://relay.example.com", text: $relayURLText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save Relay") {
                        guard let url = URL(string: relayURLText),
                              url.scheme?.lowercased() == "https" else {
                            validationMessage = "Enter a valid HTTPS URL."
                            return
                        }
                        validationMessage = nil
                        Task { await state.setRelayBaseURL(url) }
                    }
                    Button("Disable Relay") {
                        relayURLText = ""
                        validationMessage = nil
                        Task { await state.setRelayBaseURL(nil) }
                    }
                    .disabled(state.relayBaseURL == nil)
                }
                if let validationMessage {
                    Text(validationMessage).foregroundStyle(CompanionDeckColor.danger)
                }
                if state.relayBaseURL == nil {
                    Text("Approval and completion alerts need a configured relay on this Mac (§14.3). Until then, no background alerts are sent.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Alerts are pre-redacted on this Mac and delivered via the notification relay.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { relayURLText = state.relayBaseURL?.absoluteString ?? "" }
    }
}

private struct SecurityPane: View {
    var body: some View {
        Form {
            Section("Device Security") {
                LabeledContent("Private keys", value: "Keychain (this device only)")
                LabeledContent("Pairing", value: "Ed25519 with mutual verification phrase")
                LabeledContent("Approvals", value: "Device authentication for critical actions")
            }
        }
        .formStyle(.grouped)
    }
}

private struct DiagnosticsSettingsPane: View {
    let state: AppState

    var body: some View {
        Form {
            Section("Diagnostics") {
                Button("Export Diagnostics…") {
                    Task { await DiagnosticsExporter.export(from: state) }
                }
                Text("Exports a redacted snapshot — no secrets, no code, no terminal output.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutPane: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Product", value: ProductNaming.name)
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                LabeledContent("Role", value: "macOS companion — the authenticated boundary")
            }
        }
        .formStyle(.grouped)
    }
}
