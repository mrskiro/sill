import AppKit
import SillCore

/// Help › Check for Updates…: one request to the GitHub releases API, only when asked.
/// Sill has no background updater, so this is the whole update story on the Mac.
@MainActor
enum UpdateCheck {
    /// `runModal()` keeps draining the main actor, so a second pick while the first request is in
    /// flight would stack a second alert on top of the first.
    private static var isChecking = false

    static func run() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        do {
            let tag = try await latestTag()
            if Support.isNewer(tag: tag, than: current) {
                offer(tag: tag, current: current)
            } else {
                show(
                    "Sill is up to date.", "You are running \(current).",
                    buttons: ["OK"])
            }
        } catch {
            show("Could not check for updates.", error.localizedDescription, buttons: ["OK"])
        }
    }

    /// The alert shows `localizedDescription`, so every case here has to read as a sentence.
    private enum CheckError: LocalizedError {
        case noRelease
        case rateLimited
        case status(Int)

        var errorDescription: String? {
            switch self {
            case .noRelease: "No release has been published yet."
            case .rateLimited: "GitHub is rate limiting update checks. Try again in a while."
            case .status(let code): "GitHub returned HTTP \(code)."
            }
        }
    }

    private struct Release: Decodable {
        let tagName: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
        }
    }

    private static func latestTag() async throws -> String {
        var request = URLRequest(url: Support.latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200: break
        // Unauthenticated requests are capped per IP, and a repo with no release yet answers 404.
        case 403, 429: throw CheckError.rateLimited
        case 404: throw CheckError.noRelease
        default: throw CheckError.status(http.statusCode)
        }
        return try JSONDecoder().decode(Release.self, from: data).tagName
    }

    private static func offer(tag: String, current: String) {
        let clicked = show(
            "Sill \(tag) is available.",
            """
            You are running \(current).

            Installed with Homebrew? Run: brew upgrade --cask sill
            """,
            buttons: ["Download", "Later"])
        if clicked == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Support.latestReleaseURL)
        }
    }

    /// The panel is not a normal window, so bring the app forward before running the alert.
    @discardableResult
    private static func show(_ message: String, _ detail: String, buttons: [String]) -> NSApplication.ModalResponse {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        for title in buttons { alert.addButton(withTitle: title) }
        return alert.runModal()
    }
}
