import AppKit
import CoreImage.CIFilterBuiltins
import SillCore
import SwiftUI

/// Settings content: show the pairing code (as a QR for the phone, as text for another Mac),
/// take a code from another Mac, list paired devices.
struct PairingView: View {
    let sync: MacSync
    @State private var pastedCode = ""
    @State private var codeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let payload = sync.pairingPayload {
                Text("Scan this with Sill on your iPhone, or copy the code and paste it into Sill on the other Mac.")
                    .font(.callout)
                QRCodeView(string: payload.qrString)
                    .frame(width: 220, height: 220)
                HStack {
                    Button("Copy Code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(payload.qrString, forType: .string)
                    }
                    Button("Cancel") { Task { await sync.endPairing() } }
                }
            } else {
                Button("Pair a Device…") { Task { await sync.beginPairing() } }
            }
            Divider()
            Text("Have a code from another Mac?")
                .font(.callout)
            TextField("Paste the pairing code", text: $pastedCode)
                .onSubmit { pair() }
            HStack {
                Button("Pair") { pair() }
                    .disabled(pastedCode.isEmpty)
                if let codeError {
                    Text(codeError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            if !sync.peers.isEmpty {
                Divider()
                ForEach(sync.peers) { peer in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(peer.name)
                            Text(
                                peer.lastSyncAt.map { "Synced \($0.formatted(.relative(presentation: .named)))" }
                                    ?? "Never synced"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Unpair") { sync.unpair(peer.id) }
                    }
                }
            }
            Text(sync.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 320)
    }

    private func pair() {
        guard let payload = PairingPayload(qrString: pastedCode.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            SyncLog.write("mac: invalid pairing code (\(pastedCode.count) chars)")
            codeError = "That is not a Sill pairing code."
            return
        }
        guard payload.deviceID != sync.store.deviceID else {
            codeError = "That code is from this Mac."
            return
        }
        codeError = nil
        pastedCode = ""
        sync.pair(with: payload)
    }
}

struct QRCodeView: View {
    let string: String

    var body: some View {
        if let image = Self.image(for: string) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Text("Could not render QR code")
        }
    }

    static func image(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
