import SillCore
import SwiftUI
import VisionKit

/// Sheet: pair with a Mac (scan its QR, or paste the code), see and unpair devices.
struct PairingScreen: View {
    let sync: PhoneSync
    @Environment(\.dismiss) private var dismiss
    @State private var pastedCode = ""
    @State private var showScanner = false
    @State private var invalidCode = false

    private var canScan: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if canScan {
                        Button("Scan QR code on the Mac", systemImage: "qrcode.viewfinder") { showScanner = true }
                    } else {
                        // No usable camera (simulator, or camera access denied): accept the code as text.
                        // The code carries the one-time token, so this path is kept off devices that can scan.
                        TextField("Paste the pairing code", text: $pastedCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Pair") { pair(code: pastedCode) }
                            .disabled(pastedCode.isEmpty)
                    }
                } header: {
                    Text("Pair with a Mac")
                } footer: {
                    Text(
                        invalidCode ? "That is not a Sill pairing code." : "On the Mac: Sill › Settings › Pair iPhone.")
                }
                if !sync.peers.isEmpty {
                    Section("Paired devices") {
                        ForEach(sync.peers) { peer in
                            VStack(alignment: .leading) {
                                Text(peer.name)
                                Text(
                                    peer.lastSyncAt.map { "Synced \($0.formatted(.relative(presentation: .named)))" }
                                        ?? "Never synced"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .swipeActions { Button("Unpair", role: .destructive) { sync.unpair(peer.id) } }
                        }
                    }
                }
                Section { Text(sync.status.text).foregroundStyle(.secondary) }
                Section {
                    Link(
                        "Report an Issue",
                        destination: Support.newIssueURL(environment: Support.environmentSummary()))
                    Link("Privacy Policy", destination: Support.privacyPolicyURL)
                } footer: {
                    Text(Support.environmentSummary())
                }
            }
            .navigationTitle("Sync")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showScanner) {
                QRScannerView { code in
                    showScanner = false
                    pair(code: code)
                }
            }
        }
    }

    private func pair(code: String) {
        guard let payload = PairingPayload(qrString: code.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            SyncLog.write("phone: invalid pairing code (\(code.count) chars, prefix \(code.prefix(8)))")
            invalidCode = true
            return
        }
        invalidCode = false
        pastedCode = ""
        sync.pair(with: payload)
    }
}

/// VisionKit scanner limited to QR codes. Real devices only; the simulator has no camera.
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(
            _ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                if case .barcode(let barcode) = item {
                    SyncLog.write("phone: scanned barcode \(barcode.payloadStringValue?.prefix(12) ?? "-")")
                }
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue,
                    payload.hasPrefix("sill:")
                {
                    scanner.stopScanning()
                    onCode(payload)
                    return
                }
            }
        }
    }
}
