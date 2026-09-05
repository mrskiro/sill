import CoreImage.CIFilterBuiltins
import SillCore
import SwiftUI

/// Settings content: show the pairing QR, list paired devices.
struct PairingView: View {
    let sync: MacSync

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let payload = sync.pairingPayload {
                Text("Scan this with Sill on your iPhone.")
                QRCodeView(string: payload.qrString)
                    .frame(width: 220, height: 220)
                Button("Cancel") { Task { await sync.endPairing() } }
            } else {
                Button("Pair iPhone…") { Task { await sync.beginPairing() } }
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
