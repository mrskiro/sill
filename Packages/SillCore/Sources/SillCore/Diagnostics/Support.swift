import Foundation

/// Where a user reports a problem. The query keys below are the field ids in
/// `.github/ISSUE_TEMPLATE/bug.yml`; GitHub prefills the form from them, so the two must stay in step.
public enum Support {
    public static let repository = URL(string: "https://github.com/mrskiro/sill")!

    /// e.g. `Sill 0.1.0 (12) · macOS 26.6`. Both apps send the same shape so issues sort by it.
    public static func environmentSummary(
        bundle: Bundle = .main,
        platform: String = platformName,
        os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var version = "\(os.majorVersion).\(os.minorVersion)"
        if os.patchVersion > 0 { version += ".\(os.patchVersion)" }
        return "Sill \(short) (\(build)) · \(platform) \(version)"
    }

    public static var platformName: String {
        #if os(macOS)
            "macOS"
        #else
            "iOS"
        #endif
    }

    /// Where "Check for Updates…" looks. Unauthenticated and only requested when the user asks:
    /// Sill never polls for updates on its own.
    public static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/mrskiro/sill/releases/latest")!

    public static var latestReleaseURL: URL { repository.appending(path: "releases/latest") }

    /// `v0.2.0` is newer than `0.1.0`. Only the numeric components count, so a prerelease tag
    /// (`v0.2.0-beta.1`) compares as its release version rather than as something newer.
    public static func isNewer(tag: String, than current: String) -> Bool {
        let new = versionComponents(tag)
        let old = versionComponents(current)
        guard !new.isEmpty else { return false }
        for index in 0..<max(new.count, old.count) {
            let left = index < new.count ? new[index] : 0
            let right = index < old.count ? old[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    static func versionComponents(_ string: String) -> [Int] {
        string.drop { !$0.isNumber }
            .prefix { $0.isNumber || $0 == "." }
            .split(separator: ".")
            .compactMap { Int($0) }
    }

    public static func newIssueURL(environment: String) -> URL {
        var components = URLComponents(
            url: repository.appending(path: "issues/new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "template", value: "bug.yml"),
            URLQueryItem(name: "environment", value: environment),
        ]
        return components.url!
    }
}
