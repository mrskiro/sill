import SillCore
import SwiftUI
import UIKit

@main
struct SillApp: App {
    private let model: PhoneModel

    init() {
        do {
            model = try PhoneModel.make()
        } catch {
            fatalError("Sill cannot open its database: \(error)")
        }
        PhoneModel.shared = model
        // Hosted tests drive navigation directly; transitions would only add latency and races.
        if PhoneModel.isTestMode { UIView.setAnimationsEnabled(false) }
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
