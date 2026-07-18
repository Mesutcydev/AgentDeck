//
//  PairingWindowView.swift
//  Companion — AgentDeck
//
//  §13.2 QR pairing window: live offer, countdown, and copy payload.
//

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import Shared

struct PairingWindowView: View {
    let state: AppState
    @State private var offer: PairingOffer?
    @State private var remainingSeconds = 0
    @State private var qrImage: NSImage?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            CompanionPageHeader(
                index: "02 / TRUST LINK",
                title: "Pair a device",
                detail: "Scan the short-lived offer in AgentDeck. Compare the verification phrase on both screens before accepting."
            )

            HStack(alignment: .top, spacing: 28) {
                if let qrImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 238, height: 238)
                        .padding(12)
                        .background(.white)
                        .overlay(alignment: .top) { Rectangle().fill(CompanionDeckColor.signal).frame(height: 3) }
                        .accessibilityLabel("Pairing QR code")
                } else {
                    ProgressView()
                        .frame(width: 262, height: 262)
                }

                VStack(alignment: .leading, spacing: 14) {
                    CompanionSectionLabel(index: "01", title: "Live offer")
                    HStack(spacing: 4) {
                        ForEach(0..<5, id: \.self) { index in
                            Rectangle()
                                .fill(index < expiryLevel ? CompanionDeckColor.signal : CompanionDeckColor.rule)
                                .frame(width: 28, height: 4)
                        }
                    }
                    Text("\(remainingSeconds) SEC")
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .foregroundStyle(CompanionDeckColor.ink)
                    if let endpoint = offer?.payload.endpoint.description {
                        dataRow("ENDPOINT", endpoint)
                    }
                    if let port = state.sessionService?.boundPort {
                        dataRow("PORT", "\(port)")
                    }
                    Button {
                        if let offer, let encoded = try? offer.payload.encoded() {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(encoded, forType: .string)
                        }
                    } label: {
                        Label("COPY PAIRING PAYLOAD", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(CompanionActionStyle(primary: true, tint: CompanionDeckColor.ink))
                    .disabled(offer == nil)
                    Button {
                        Task { await refreshOffer() }
                    } label: {
                        Label("REFRESH OFFER", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(CompanionActionStyle(tint: CompanionDeckColor.signal))
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(CompanionDeckColor.danger)
                    .font(.callout)
            }

            if state.remoteAccessPaused {
                Text("Remote access is paused — enable it before pairing.")
                    .foregroundStyle(CompanionDeckColor.warning)
            }
        }
        .padding(30)
        .frame(width: 680)
        .foregroundStyle(CompanionDeckColor.ink)
        .background(CompanionDeckColor.canvas)
        .preferredColorScheme(.light)
        .task {
            await refreshOffer()
            await runCountdown()
        }
    }

    private var expiryLevel: Int {
        max(0, min(5, Int(ceil(Double(remainingSeconds) / 24.0))))
    }

    private func dataRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(CompanionDeckFont.label).foregroundStyle(CompanionDeckColor.muted)
            Text(value).font(CompanionDeckFont.mono).textSelection(.enabled)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(CompanionDeckColor.rule).frame(height: 1) }
    }

    private func refreshOffer() async {
        errorMessage = state.sessionService?.lastError
        guard !state.remoteAccessPaused else {
            offer = nil
            qrImage = nil
            return
        }
        offer = await state.sessionService?.makePairingOffer()
        if let offer {
            if let encoded = try? offer.payload.encoded() {
                qrImage = Self.makeQRImage(from: encoded)
            }
            remainingSeconds = offer.remainingSeconds(now: Date.unixMillisecondsNow)
        }
    }

    private func runCountdown() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let offer {
                let now = Date.unixMillisecondsNow
                remainingSeconds = offer.remainingSeconds(now: now)
                if offer.isExpired(now: now) {
                    await refreshOffer()
                }
            }
        }
    }

    private static func makeQRImage(from text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
