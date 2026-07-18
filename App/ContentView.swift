//
//  ContentView.swift
//  App — AgentDeck
//
//  §13 minimal iOS UI: device list, QR scanning / manual payload entry,
//  and revoke. The scanner is isolated from parsing so the pairing-payload
//  logic stays testable without a camera.
//

import AVFoundation
import SwiftUI
import Shared
import UIKit

/// Pure seam for the scanner: turns a scanned string into a QR payload.
/// Unit-testable without AVFoundation or a camera.
enum QRScanParser {
    static func payload(from scannedText: String) -> PairingQRPayload? {
        try? PairingQRPayload.decode(scannedText)
    }

    /// Camera scanning is offered only when the app was built with a camera
    /// usage description AND a capture device exists (simulators have none).
    static var isCameraScanningAvailable: Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else {
            return false
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }
}

struct ContentView: View {
    @State var state: IOSAppState
    @State private var qrText = ""
    @State private var isPairing = false
    @State private var isShowingScanner = false
    @State private var devicePendingRevoke: DeviceRecord?

    var body: some View {
        NavigationStack {
            List {
                DeckPageHeader(
                    index: "04",
                    title: "Macs",
                    detail: "Trusted endpoints that host your local agents and project workspaces."
                )
                .listRowInsets(EdgeInsets(top: 0, leading: DeckSpace.m, bottom: DeckSpace.l, trailing: DeckSpace.m))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    if state.pairedDevices.isEmpty {
                        DeckEmptyLedger(
                            index: "00",
                            title: "No endpoints",
                            detail: "Pair a trusted Mac to open the local agent channel.",
                            systemImage: "desktopcomputer",
                            accent: DeckColor.ink
                        )
                    } else {
                        ForEach(state.pairedDevices, id: \.id) { device in
                            DeviceRow(
                                device: device,
                                isActive: device.id == state.activeHostID,
                                isConnected: state.connectedDeviceIDs.contains(device.id),
                                select: { Task { await state.selectHost(device.id) } },
                                requestRevoke: { devicePendingRevoke = device }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Revoke", systemImage: "xmark.shield", role: .destructive) {
                                    devicePendingRevoke = device
                                }
                            }
                        }
                    }
                } header: {
                    DeckSectionLabel(title: "Paired Macs", eyebrow: "Remote endpoints", systemImage: "desktopcomputer")
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    VStack(spacing: 0) {
                        if QRScanParser.isCameraScanningAvailable {
                            Button {
                                isShowingScanner = true
                            } label: {
                                Label("SCAN PAIRING CODE", systemImage: "qrcode.viewfinder")
                                    .font(DeckFont.monoSmall.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 52)
                            }
                            .buttonStyle(DeckActionButtonStyle(primary: true))
                        }
                        VStack(alignment: .leading, spacing: DeckSpace.s) {
                            HStack {
                                Text("MANUAL / PAYLOAD")
                                Spacer()
                                Text(qrText.isEmpty ? "EMPTY" : "READY")
                                    .foregroundStyle(qrText.isEmpty ? DeckColor.ink.opacity(0.36) : DeckColor.success)
                            }
                            .font(.caption2.monospaced().weight(.semibold))
                            TextField("Paste encrypted QR payload", text: $qrText, axis: .vertical)
                                .font(DeckFont.monoSmall)
                                .textFieldStyle(.plain)
                                .lineLimit(3...6)
                                .padding(DeckSpace.s)
                                .background(DeckColor.canvas)
                                .overlay(alignment: .leading) { Rectangle().fill(DeckColor.accent).frame(width: 2) }
                            Button {
                                Task { await startPairing(with: qrText) }
                            } label: {
                                HStack {
                                    Text(isPairing ? "OPENING SECURE CHANNEL" : "PAIR ENDPOINT")
                                    Spacer()
                                    if isPairing { ProgressView().controlSize(.small) }
                                    else { Image(systemName: "arrow.right") }
                                }
                                .font(DeckFont.monoSmall.weight(.semibold))
                                .padding(.horizontal, DeckSpace.m)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                            }
                            .buttonStyle(DeckActionButtonStyle(primary: true))
                            .disabled(qrText.isEmpty || isPairing || state.identity == nil)
                        }
                        .padding(DeckSpace.m)
                        .background(DeckColor.surfaceRaised)
                        .overlay(alignment: .leading) { Rectangle().fill(DeckColor.accent).frame(width: 3) }
                    }
                } header: {
                    DeckSectionLabel(title: "Pair a Mac", eyebrow: "Add endpoint", systemImage: "qrcode")
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if let error = state.error(for: .pairing) {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(DeckFont.caption)
                            .foregroundStyle(DeckColor.danger)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { DeckCanvas() }
            .tint(DeckColor.accent)
            .listStyle(.plain)
            .listSectionSpacing(DeckSpace.xl)
            .navigationTitle("")
            .task {
                await state.loadIdentity()
                await state.refreshDevices()
            }
            .refreshable {
                await state.refreshDevices()
            }
            .alert("Revoke \(devicePendingRevoke?.displayName ?? "this Mac")?", isPresented: revokeAlertPresented) {
                Button("Cancel", role: .cancel) {}
                Button("Revoke", role: .destructive) {
                    if let device = devicePendingRevoke {
                        DeckHaptics.warning()
                        Task { await state.revoke(device) }
                    }
                }
            } message: {
                Text("The Mac loses access immediately and must pair again to reconnect.")
            }
            .sheet(isPresented: $isShowingScanner) {
                NavigationStack {
                    QRScannerSheet { scannedText in
                        isShowingScanner = false
                        if QRScanParser.payload(from: scannedText) != nil {
                            Task { await startPairing(with: scannedText) }
                        } else {
                            state.setError("Scanned code is not a valid AgentDeck pairing QR.", domain: .pairing)
                        }
                    }
                    .navigationTitle("Scan Pairing QR")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { isShowingScanner = false }
                        }
                    }
                }
            }
        }
    }

    private var revokeAlertPresented: Binding<Bool> {
        Binding(
            get: { devicePendingRevoke != nil },
            set: { if !$0 { devicePendingRevoke = nil } }
        )
    }

    private func startPairing(with payloadText: String) async {
        isPairing = true
        defer { isPairing = false }
        guard let payload = QRScanParser.payload(from: payloadText) else {
            state.setError("Invalid QR payload — scan the code shown on your Mac or paste its text.", domain: .pairing)
            return
        }
        await state.pair(with: payload)
        qrText = ""
    }
}

private struct DeviceRow: View {
    let device: DeviceRecord
    let isActive: Bool
    let isConnected: Bool
    let select: () -> Void
    let requestRevoke: () -> Void

    var body: some View {
        HStack(spacing: DeckSpace.s) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(device.revoked ? Color(.tertiaryLabel) : DeckColor.accent)
                .frame(width: 24, height: 28)
            VStack(alignment: .leading, spacing: DeckSpace.xxs) {
                Text(device.displayName)
                    .font(DeckFont.callout.weight(.semibold))
                Text(device.id.wireString)
                    .font(DeckFont.monoSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if device.revoked {
                Text("Revoked")
                    .font(DeckFont.footnote.weight(.medium))
                    .foregroundStyle(DeckColor.danger)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    Button(isActive ? "ACTIVE" : "USE MAC") { select() }
                        .font(DeckFont.monoSmall.weight(.semibold))
                        .foregroundStyle(isActive ? DeckColor.success : DeckColor.accent)
                    HStack(spacing: 4) {
                        Circle().fill(isConnected ? DeckColor.success : Color(.tertiaryLabel)).frame(width: 5, height: 5)
                        Text(isConnected ? "CONNECTED" : "OFFLINE")
                    }
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, DeckSpace.xxs)
        .accessibilityElement(children: .combine)
        .contextMenu {
            if !device.revoked && !isActive {
                Button("Use This Mac", systemImage: "arrow.triangle.swap") { select() }
            }
            Button("Revoke", systemImage: "xmark.shield", role: .destructive) { requestRevoke() }
        }
    }
}

/// Camera sheet for scanning the Mac's pairing QR. Delivers raw scanned
/// strings; parsing lives in `QRScanParser` (kept camera-free for tests).
private struct QRScannerSheet: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

/// AVCaptureSession is thread-safe for start/stop but predates Sendable;
/// box it for Apple's recommended background start/stop hops so the UI
/// thread never blocks on camera bring-up.
private struct SendableCaptureSession: @unchecked Sendable {
    let session: AVCaptureSession

    func start() { session.startRunning() }
    func stop() { session.stopRunning() }
}

private final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?

    private let captureSession = AVCaptureSession()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let statusLabel = UILabel()
    private var didDeliverCode = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        statusLabel.textColor = .white
        statusLabel.font = .preferredFont(forTextStyle: .callout)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = "Requesting camera access…"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])

        previewLayer.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(previewLayer, at: 0)

        requestCameraAccess()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if captureSession.isRunning {
            let session = SendableCaptureSession(session: captureSession)
            DispatchQueue.global(qos: .userInitiated).async {
                session.stop()
            }
        }
    }

    private func requestCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureCaptureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { [weak self] in
                    if granted {
                        self?.configureCaptureSession()
                    } else {
                        self?.statusLabel.text = "Camera access denied. Enable it in Settings, or paste the QR payload instead."
                    }
                }
            }
        default:
            statusLabel.text = "Camera access denied. Enable it in Settings, or paste the QR payload instead."
        }
    }

    private func configureCaptureSession() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            statusLabel.text = "No camera available — paste the QR payload instead."
            return
        }
        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else {
            statusLabel.text = "QR scanning is unavailable on this device."
            return
        }
        captureSession.beginConfiguration()
        captureSession.addInput(input)
        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        if output.availableMetadataObjectTypes.contains(.qr) {
            output.metadataObjectTypes = [.qr]
        }
        captureSession.commitConfiguration()
        previewLayer.session = captureSession
        statusLabel.text = "Point the camera at the QR code shown on your Mac."
        let session = SendableCaptureSession(session: captureSession)
        DispatchQueue.global(qos: .userInitiated).async {
            session.start()
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.didDeliverCode else { return }
            self.didDeliverCode = true
            if self.captureSession.isRunning {
                let session = SendableCaptureSession(session: self.captureSession)
                DispatchQueue.global(qos: .userInitiated).async {
                    session.stop()
                }
            }
            self.onCode?(value)
        }
    }
}
