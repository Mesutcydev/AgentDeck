//
//  MainTabView.swift
//  App — AgentDeck
//
//  §17 tab shell on the native iOS 26 glass tab bar (minimize-on-scroll).
//  Approvals inbox/detail and the §13.2 pairing sheet live here, styled
//  per docs/DESIGN.md tokens.
//

import SwiftUI
import Shared

struct MainTabView: View {
    @Bindable var state: IOSAppState
    @State private var selectedTab: IOSAppState.AppTab = .home

    var body: some View {
        VStack(spacing: 0) {
            if state.isStoreDegraded {
                HStack(spacing: DeckSpace.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                    Text("Session history is in memory only — it will not survive relaunch.")
                        .font(DeckFont.footnote)
                }
                .foregroundStyle(.black)
                .padding(.horizontal, DeckSpace.s)
                .padding(.vertical, DeckSpace.xxs + 2)
                .frame(maxWidth: .infinity)
                .background(DeckColor.warning.opacity(0.85))
            }
            TabView(selection: $selectedTab) {
                HomeView(state: state)
                    .tabItem { Label("Home", systemImage: "house") }
                    .tag(IOSAppState.AppTab.home)
                SessionsListView(state: state)
                    .tabItem { Label("Sessions", systemImage: "terminal") }
                    .tag(IOSAppState.AppTab.sessions)
                ApprovalInboxView(state: state)
                    .tabItem { Label("Approvals", systemImage: "checkmark.shield") }
                    .badge(state.pendingApprovalRecords.count)
                    .tag(IOSAppState.AppTab.approvals)
                ContentView(state: state)
                    .tabItem { Label("Macs", systemImage: "desktopcomputer") }
                    .tag(IOSAppState.AppTab.macs)
                SettingsTabView(state: state)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(IOSAppState.AppTab.settings)
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .tint(DeckColor.accent)
        }
        .sensoryFeedback(.selection, trigger: selectedTab)
        .task {
            await state.loadIdentity()
            await state.refreshDevices()
            await state.refreshSessions()
            await state.refreshProjects()
            await state.startRemoteConnections()
            await state.refreshApprovalState()
        }
        .sheet(item: pairingConfirmationBinding) { request in
            PairingConfirmationSheet(request: request) { confirmed in
                state.respondToPairingConfirmation(confirmed: confirmed)
            }
        }
        .fullScreenCover(isPresented: $state.paywallPresented) {
            PaywallView(
                manager: state.subscription,
                launchesUsed: state.freeLaunchCount,
                dismiss: { state.paywallPresented = false }
            )
        }
        .onOpenURL { url in
            if let link = IOSAppState.parseDeepLink(url) {
                state.handleDeepLink(link)
            }
        }
        .onChange(of: state.deepLinkNonce) {
            if let tab = state.consumeRequestedTab() {
                selectedTab = tab
            }
        }
    }

    /// Swipe-to-dismiss without a decision counts as Reject (fail closed).
    private var pairingConfirmationBinding: Binding<PairingConfirmationRequest?> {
        Binding(
            get: { state.pendingPairingConfirmation },
            set: { newValue in
                if newValue == nil {
                    state.respondToPairingConfirmation(confirmed: false)
                }
            }
        )
    }

}

/// §13.2 human confirmation (DESIGN §7.8): the user compares the
/// verification phrase and fingerprint with the Mac, then explicitly
/// confirms or rejects pairing.
private struct PairingConfirmationSheet: View {
    let request: PairingConfirmationRequest
    let respond: (Bool) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DeckSpace.xl) {
                    VStack(spacing: DeckSpace.s) {
                        Image(systemName: "person.badge.key.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(DeckColor.accent)
                        Text("Confirm this is your Mac")
                            .font(DeckFont.subhead)
                        Text("Compare the verification phrase with the one shown on “\(request.peerDisplayName)”. Only confirm if both match exactly.")
                            .font(DeckFont.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, DeckSpace.s)

                    VStack(alignment: .leading, spacing: DeckSpace.xs) {
                        Text("Verification Phrase")
                            .font(DeckFont.caption.weight(.semibold))
                        Text(request.phrase)
                            .font(.system(size: 17, design: .monospaced))
                            .kerning(1.2)
                            .textSelection(.enabled)
                            .padding(DeckSpace.m)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: DeckSpace.xs) {
                        Text("Key Fingerprint")
                            .font(DeckFont.caption.weight(.semibold))
                        Text(request.fingerprint)
                            .font(DeckFont.monoSmall)
                            .textSelection(.enabled)
                    }

                    if let endpoint = request.endpoint {
                        LabeledContent("Endpoint", value: endpoint)
                            .font(DeckFont.callout)
                    }

                    HStack(spacing: DeckSpace.s) {
                        Button("Reject", role: .destructive) {
                            DeckHaptics.error()
                            respond(false)
                        }
                        .buttonStyle(.glass)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)

                        Button("Confirm Pairing") {
                            DeckHaptics.success()
                            respond(true)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(DeckColor.success)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                    }
                }
                .padding(DeckSpace.l)
            }
            .navigationTitle("Pairing")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
        }
    }
}

// MARK: - Approvals inbox (§7.5)

private struct ApprovalInboxView: View {
    @Bindable var state: IOSAppState
    @State private var selectedRequestID: ApprovalRequestID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedRequestID) {
                DeckPageHeader(
                    index: "03",
                    title: "Approvals",
                    detail: "Review exact actions at the point where an agent crosses a trust boundary."
                )
                .listRowInsets(EdgeInsets(top: 0, leading: DeckSpace.m, bottom: DeckSpace.l, trailing: DeckSpace.m))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if let error = state.error(for: .approval) {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(DeckFont.caption)
                            .foregroundStyle(DeckColor.danger)
                    }
                }

                Section {
                    if state.pendingApprovalRecords.isEmpty {
                        DeckEmptyLedger(
                            index: "00",
                            title: "Everything approved",
                            detail: "No actions require attention.",
                            systemImage: "checkmark.circle.fill",
                            accent: DeckColor.success
                        )
                    } else {
                        ForEach(state.pendingApprovalRecords, id: \.request.id) { record in
                            VStack(alignment: .leading, spacing: DeckSpace.xxs) {
                                Text(record.request.explanation)
                                    .font(DeckFont.caption.weight(.semibold))
                                    .lineLimit(2)
                                Text(record.request.exactAction)
                                    .font(DeckFont.monoSmall)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                HStack(spacing: DeckSpace.xs) {
                                    RiskBadgeView(risk: record.request.effectiveRisk)
                                    if let expiresAt = record.request.expiresAt {
                                        ApprovalExpiryView(expiresAtUnixMilliseconds: expiresAt)
                                    }
                                }
                            }
                            .padding(.vertical, DeckSpace.xxs)
                            .tag(record.request.id)
                        }
                    }
                } header: {
                    DeckSectionLabel(title: "Pending", eyebrow: "Needs a decision", systemImage: "checkmark.shield")
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    if state.approvalRules.isEmpty {
                        DeckEmptyLedger(
                            index: "00",
                            title: "No trust rules",
                            detail: "No permanent permissions.",
                            systemImage: "slider.horizontal.3",
                            accent: DeckColor.ink
                        )
                    } else {
                        ForEach(state.approvalRules, id: \.id) { rule in
                            VStack(alignment: .leading, spacing: DeckSpace.xxs) {
                                Text(rule.displayText)
                                    .font(DeckFont.callout)
                                Text(rule.choice.rawValue)
                                    .font(DeckFont.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .contextMenu {
                                Button("Revoke Rule", role: .destructive) {
                                    DeckHaptics.warning()
                                    Task { await state.revokeRule(rule) }
                                }
                            }
                        }
                    }
                } header: {
                    DeckSectionLabel(title: "Active rules", eyebrow: "Remembered scope", systemImage: "slider.horizontal.3")
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    if state.approvalAuditEntries.isEmpty {
                        DeckEmptyLedger(
                            index: "00",
                            title: "No decisions yet",
                            detail: "Approval history will appear here.",
                            systemImage: "clock.arrow.circlepath",
                            accent: DeckColor.ink
                        )
                    } else {
                        ForEach(state.approvalAuditEntries, id: \.id) { entry in
                            VStack(alignment: .leading, spacing: DeckSpace.xxs) {
                                Text(entry.summary)
                                    .font(DeckFont.callout)
                                Text(entry.eventKind.rawValue)
                                    .font(DeckFont.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    DeckSectionLabel(title: "Recent audit", eyebrow: "Decision trail", systemImage: "clock.arrow.circlepath")
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .scrollContentBackground(.hidden)
            .background { DeckCanvas() }
            .listStyle(.plain)
            .listSectionSpacing(18)
            .navigationTitle("")
        } detail: {
            if let record = state.pendingApprovalRecords.first(where: { $0.request.id == selectedRequestID }) {
                ApprovalDetailView(state: state, request: record.request)
            } else {
                VStack(alignment: .leading, spacing: DeckSpace.s) {
                    Text("03 / APPROVAL DETAIL")
                        .font(DeckFont.monoSmall.weight(.semibold))
                        .foregroundStyle(DeckColor.accent)
                    Text("Select a pending request to inspect its exact action, risk, and allowed scope.")
                        .font(DeckFont.subhead)
                }
                .padding(DeckSpace.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background { DeckCanvas() }
            }
        }
        .task {
            await state.refreshApprovalState()
            if selectedRequestID == nil {
                selectedRequestID = state.pendingApprovalRecords.first?.request.id
            }
        }
        .refreshable {
            await state.refreshApprovalState()
            if selectedRequestID == nil {
                selectedRequestID = state.pendingApprovalRecords.first?.request.id
            }
        }
    }
}

private struct ApprovalDetailView: View {
    @Bindable var state: IOSAppState
    let request: ApprovalRequest
    @State private var commandPattern: String
    @State private var resolvedChoice: ApprovalChoice?

    init(state: IOSAppState, request: ApprovalRequest) {
        self.state = state
        self.request = request
        _commandPattern = State(initialValue: request.exactAction)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DeckSpace.xl) {
                DeckPageHeader(
                    index: "03.1",
                    title: "Trust review",
                    detail: "Inspect the exact action, then choose how far this permission should reach."
                )
                trustBoundarySection
                reachSection
                ruleInputSection
                authoritySection
            }
            .padding(DeckSpace.l)
        }
        .background { DeckCanvas() }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: resolvedChoice) { _, choice in
            choice?.authorizes == true
        }
        .sensoryFeedback(.warning, trigger: resolvedChoice) { _, choice in
            choice?.authorizes == false
        }
    }

    private var trustBoundarySection: some View {
        VStack(alignment: .leading, spacing: DeckSpace.m) {
            HStack(alignment: .top) {
                sectionLabel("01 / TRUST BOUNDARY")
                Spacer()
                ApprovalRiskMeter(risk: request.effectiveRisk, inactiveColor: DeckColor.rule)
            }
            Text(request.explanation)
                .font(DeckFont.subhead)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DeckSpace.xs) {
                Text(request.tool.uppercased())
                Text("/")
                Text(request.workingDirectory)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption2.monospaced())
            .foregroundStyle(DeckColor.ink.opacity(0.48))
            HStack(alignment: .firstTextBaseline, spacing: DeckSpace.s) {
                Text(">").foregroundStyle(DeckColor.accent)
                Text(request.exactAction)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(DeckFont.mono)
            .padding(DeckSpace.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DeckColor.surfaceRaised)
            .overlay(alignment: .leading) { Rectangle().fill(DeckColor.accent).frame(width: 3) }
            if let expiresAt = request.expiresAt {
                ApprovalExpiryView(expiresAtUnixMilliseconds: expiresAt)
            }
        }
        .padding(.vertical, DeckSpace.m)
        .overlay(alignment: .top) { Rectangle().fill(DeckColor.rule).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(DeckColor.rule).frame(height: 1) }
    }

    @ViewBuilder private var reachSection: some View {
        if !request.files.isEmpty || !request.domains.isEmpty {
            VStack(alignment: .leading, spacing: DeckSpace.s) {
                sectionLabel("02 / REACH")
                ForEach(request.files, id: \.self) { file in
                    ApprovalReachRow(kind: "FILE", value: file, symbol: "doc")
                }
                ForEach(request.domains, id: \.self) { domain in
                    ApprovalReachRow(kind: "HOST", value: domain, symbol: "network")
                }
            }
        }
    }

    private var ruleInputSection: some View {
        VStack(alignment: .leading, spacing: DeckSpace.s) {
            sectionLabel("03 / RULE INPUT")
            TextField("Command pattern", text: $commandPattern)
                .font(DeckFont.mono)
                .textFieldStyle(.plain)
                .padding(.horizontal, DeckSpace.m)
                .frame(minHeight: 48)
                .background(DeckColor.surfaceRaised)
                .overlay(alignment: .leading) { Rectangle().fill(DeckColor.ink).frame(width: 3) }
            Text("Used only if you choose the project-pattern scope below.")
                .font(DeckFont.footnote)
                .foregroundStyle(DeckColor.ink.opacity(0.48))
        }
    }

    private var authoritySection: some View {
        VStack(alignment: .leading, spacing: DeckSpace.s) {
            HStack {
                sectionLabel("04 / CHOOSE AUTHORITY")
                Spacer()
                Text("NARROW → BROAD")
                    .font(.caption2.monospaced())
                    .foregroundStyle(DeckColor.ink.opacity(0.48))
            }
            ApprovalDecisionRow(index: "00", title: "Deny request", detail: "Stop this action. Nothing is remembered.", symbol: "xmark", tint: DeckColor.danger) {
                resolve(.deny)
            }
            ApprovalDecisionRow(index: "01", title: "Allow once", detail: "Authorize this exact action for this run only.", symbol: "arrow.right", tint: DeckColor.accent, isPrimary: true) {
                resolve(.allowOnce)
            }
            broaderAuthorityRows
            if request.isReadOnlyOperation {
                ApprovalDecisionRow(index: "RO", title: "Allow read-only actions", detail: "Permit inspection, but never writes or execution.", symbol: "eye", tint: DeckColor.info) {
                    resolve(.allowReadOnlyActions)
                }
            }
        }
    }

    @ViewBuilder private var broaderAuthorityRows: some View {
        if request.effectiveRisk.requiresSecureConfirmation {
            Label("Broader access requires a deliberate hold and device authentication.", systemImage: "lock.shield")
                .font(DeckFont.callout)
                .foregroundStyle(DeckColor.warning)
            HoldToConfirmButton(title: "Hold · Allow for this session") { resolve(.allowSession) }
            HoldToConfirmButton(title: "Hold · Allow matching commands") {
                resolve(.allowCommandPatternInProject, pattern: commandPattern)
            }
        } else {
            ApprovalDecisionRow(index: "02", title: "Allow this session", detail: "Reuse permission until this agent session ends.", symbol: "clock.arrow.circlepath", tint: DeckColor.ink) {
                resolve(.allowSession)
            }
            ApprovalDecisionRow(index: "03", title: "Allow matching commands", detail: "Save the rule above for this project only.", symbol: "scope", tint: DeckColor.ink) {
                resolve(.allowCommandPatternInProject, pattern: commandPattern)
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(DeckFont.monoSmall.weight(.semibold))
            .foregroundStyle(DeckColor.accent)
    }

    private func resolve(_ choice: ApprovalChoice, pattern: String? = nil) {
        resolvedChoice = choice
        Task {
            await state.resolveApproval(request, choice: choice, commandPattern: pattern)
        }
    }
}

private struct ApprovalReachRow: View {
    let kind: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: DeckSpace.s) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DeckColor.accent)
                .frame(width: 22)
            Text(kind)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(DeckColor.ink.opacity(0.48))
                .frame(width: 38, alignment: .leading)
            Text(value)
                .font(DeckFont.monoSmall)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, DeckSpace.xs)
        .overlay(alignment: .bottom) { Rectangle().fill(DeckColor.rule).frame(height: 1) }
    }
}

private struct ApprovalDecisionRow: View {
    let index: String
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    var isPrimary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DeckSpace.m) {
                Text(index)
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(isPrimary ? DeckColor.canvas.opacity(0.7) : tint)
                    .frame(width: 24, alignment: .leading)
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(DeckFont.callout.weight(.semibold))
                    Text(detail)
                        .font(DeckFont.footnote)
                        .foregroundStyle(isPrimary ? DeckColor.canvas.opacity(0.68) : DeckColor.ink.opacity(0.48))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DeckSpace.xs)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(isPrimary ? DeckColor.canvas : DeckColor.ink)
            .padding(.horizontal, DeckSpace.m)
            .padding(.vertical, DeckSpace.s)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(isPrimary ? tint : DeckColor.surfaceRaised)
            .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 3) }
            .overlay { Rectangle().stroke(isPrimary ? tint : DeckColor.rule, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

/// §7.5 hold-to-confirm (critical approvals): a progress ring fills over
/// 0.8 s with ramping tick haptics; releasing early resets honestly.
private struct HoldToConfirmButton: View {
    let title: String
    let action: @MainActor () -> Void

    @State private var progress: Double = 0
    @State private var isPressing = false
    @State private var tickTimer: Timer?
    @State private var lastTickBucket = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let holdDuration: TimeInterval = 0.8

    var body: some View {
        HStack(spacing: DeckSpace.s) {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(DeckColor.warning, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 24, height: 24)
            Text(isPressing ? "Keep Holding…" : title)
                .font(DeckFont.callout.weight(.semibold))
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .background(DeckColor.warning.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous)
                .stroke(DeckColor.warning.opacity(0.5))
        )
        .scaleEffect(isPressing && !reduceMotion ? 0.98 : 1)
        .animation(DeckMotion.quick, value: isPressing)
        .onLongPressGesture(minimumDuration: holdDuration, perform: complete) { pressing in
            if pressing {
                startPress()
            } else if progress < 1 {
                cancelPress()
            }
        }
        .onDisappear { tickTimer?.invalidate() }
        .accessibilityLabel(title)
        .accessibilityHint("Touch and hold for \(Int(holdDuration * 1000)) milliseconds to confirm.")
    }

    private func startPress() {
        isPressing = true
        progress = 0
        lastTickBucket = -1
        let started = Date()
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            let elapsed = Date().timeIntervalSince(started)
            let value = min(elapsed / holdDuration, 1)
            Task { @MainActor in
                // Completion itself is delivered by the long-press gesture's
                // perform, which invalidates this timer via `complete()`.
                progress = value
                let bucket = Int(value * 5)
                if bucket > lastTickBucket, value < 1 {
                    lastTickBucket = bucket
                    DeckHaptics.holdTick(progress: value)
                }
            }
        }
    }

    private func cancelPress() {
        tickTimer?.invalidate()
        tickTimer = nil
        isPressing = false
        withAnimation(DeckMotion.quick) { progress = 0 }
    }

    private func complete() {
        tickTimer?.invalidate()
        tickTimer = nil
        isPressing = false
        progress = 1
        DeckHaptics.success()
        action()
        withAnimation(DeckMotion.quick) { progress = 0 }
    }
}
