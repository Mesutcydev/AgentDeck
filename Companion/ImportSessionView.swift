import SwiftUI
import Shared

struct ImportSessionView: View {
    let state: AppState
    @State private var selectedProjects: [String: String] = [:]
    @State private var pendingConfirmation: ExternalSessionDescriptor?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = state.externalSessionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CompanionDeckColor.danger)
                    .padding(16)
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    if state.externalSessions.isEmpty {
                        ContentUnavailableView(
                            "No resumable sessions",
                            systemImage: "terminal",
                            description: Text("Start future sessions with `agentdeck run` for guaranteed attachment.")
                        )
                        .frame(minHeight: 320)
                    } else {
                        ForEach(state.externalSessions) { descriptor in
                            sessionCard(descriptor)
                        }
                    }
                }
                .padding(20)
            }
        }
        .background(CompanionDeckColor.canvas)
        .foregroundStyle(CompanionDeckColor.ink)
        .task { state.refreshExternalSessions() }
        .alert("Confirm safe handoff", isPresented: Binding(
            get: { pendingConfirmation != nil },
            set: { if !$0 { pendingConfirmation = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingConfirmation = nil }
            Button("I stopped it — hand off") {
                guard let descriptor = pendingConfirmation else { return }
                pendingConfirmation = nil
                Task { await state.handoffExternalSession(descriptor, projectPath: projectPath(for: descriptor)) }
            }
        } message: {
            Text("AgentDeck never steals a Terminal PTY or kills a process. Confirm the original agent has exited before resuming it here.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                CompanionSectionLabel(index: "02", title: "Terminal handoff")
                Text("Import Terminal Session")
                    .font(.system(size: 30, weight: .black))
                Text("Resume verified Claude and Codex histories under AgentDeck supervision.")
                    .foregroundStyle(CompanionDeckColor.muted)
            }
            Spacer()
            Button { state.refreshExternalSessions() } label: {
                Label("REFRESH", systemImage: "arrow.clockwise")
            }
            .buttonStyle(CompanionActionStyle(tint: CompanionDeckColor.ink))
        }
        .padding(24)
        .overlay(alignment: .bottom) { Rectangle().fill(CompanionDeckColor.rule).frame(height: 1) }
    }

    private func sessionCard(_ descriptor: ExternalSessionDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if let agentID = AgentIdentifier(descriptor.providerID) {
                    CompanionProviderMark(agent: agentID, size: 36)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(providerName(descriptor.providerID)).font(.system(size: 15, weight: .bold))
                    Text(descriptor.externalSessionID).font(.caption.monospaced()).foregroundStyle(CompanionDeckColor.muted)
                }
                Spacer()
                status(descriptor.processState)
            }
            HStack {
                Label(descriptor.projectPath ?? "Project not recorded", systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(Date(timeIntervalSince1970: Double(descriptor.updatedAt) / 1000), style: .relative)
            }
            .font(.caption)
            .foregroundStyle(CompanionDeckColor.muted)

            if descriptor.projectPath == nil {
                Picker("Authorized project", selection: Binding(
                    get: { selectedProjects[descriptor.id] ?? "" },
                    set: { selectedProjects[descriptor.id] = $0 }
                )) {
                    Text("Select project").tag("")
                    ForEach(state.projectsByID.values.sorted { $0.displayName < $1.displayName }, id: \.id) {
                        Text($0.displayName).tag($0.canonicalPath)
                    }
                }
            }

            Button {
                pendingConfirmation = descriptor
            } label: {
                Label(
                    descriptor.processState == .active ? "EXIT ORIGINAL SESSION FIRST" : "SAFE HANDOFF",
                    systemImage: descriptor.processState == .active ? "pause.circle" : "arrow.right.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(CompanionActionStyle(primary: descriptor.processState != .active, tint: CompanionDeckColor.ink))
            .disabled(descriptor.processState == .active || projectPath(for: descriptor) == nil)
        }
        .padding(16)
        .background(CompanionDeckColor.surface)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(CompanionDeckColor.rule, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func projectPath(for descriptor: ExternalSessionDescriptor) -> String? {
        descriptor.projectPath ?? selectedProjects[descriptor.id].flatMap { $0.isEmpty ? nil : $0 }
    }

    private func status(_ state: ExternalSessionProcessState) -> some View {
        Text(state.rawValue.uppercased())
            .font(CompanionDeckFont.label)
            .foregroundStyle(state == .active ? CompanionDeckColor.warning : CompanionDeckColor.success)
    }

    private func providerName(_ id: String) -> String {
        id == "com.openai.codex" ? "Codex" : "Claude Code"
    }
}
