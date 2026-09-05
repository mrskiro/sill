import Foundation
import Testing

@testable import SillCore

@Suite struct SupportTests {
    @Test func summaryReadsTheBundleAndTrimsAZeroPatch() {
        let summary = Support.environmentSummary(
            platform: "macOS",
            os: OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0)
        )
        #expect(summary.hasSuffix("· macOS 26.6"))
        #expect(summary.hasPrefix("Sill "))
    }

    @Test func summaryKeepsANonZeroPatch() {
        let summary = Support.environmentSummary(
            platform: "iOS",
            os: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 2)
        )
        #expect(summary.hasSuffix("· iOS 26.1.2"))
    }

    @Test(arguments: [
        ("v0.2.0", "0.1.0", true),
        ("v0.1.1", "0.1.0", true),
        ("v1.0.0", "0.9.9", true),
        ("v0.10.0", "0.9.0", true),
        ("v0.1.0", "0.1.0", false),
        ("v0.1.0", "0.2.0", false),
        // A shorter tag is padded with zeros, not treated as older.
        ("v1", "1.0.0", false),
        ("v1.1", "1.0.3", true),
        // A prerelease compares as its release version, so it never offers itself as an update.
        ("v0.2.0-beta.1", "0.2.0", false),
        ("v0.2.0-beta.1", "0.1.0", true),
        // Nothing numeric: stay quiet rather than claim an update.
        ("nightly", "0.1.0", false),
    ])
    func comparesReleaseTags(tag: String, current: String, expected: Bool) {
        #expect(Support.isNewer(tag: tag, than: current) == expected)
    }

    /// The `environment` key must match the field id in `.github/ISSUE_TEMPLATE/bug.yml`.
    @Test func issueURLPrefillsTheBugForm() {
        let url = Support.newIssueURL(environment: "Sill 0.1.0 (1) · macOS 26.6")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.path() == "/mrskiro/sill/issues/new")
        #expect(items.contains(URLQueryItem(name: "template", value: "bug.yml")))
        #expect(items.contains(URLQueryItem(name: "environment", value: "Sill 0.1.0 (1) · macOS 26.6")))
        // Spaces and · survive as percent-encoding rather than breaking the query.
        #expect(url.absoluteString.contains("environment=Sill%200.1.0"))
    }
}
