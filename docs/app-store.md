# App Store submission (iPhone)

What goes into App Store Connect for the iOS app, so it can be pasted rather than composed
under pressure. The Mac app stays on Developer ID (`docs/distribution.md`); this is iPhone only.

## App record

| Field | Value |
|---|---|
| Name | Sill |
| Bundle ID | `com.mrskiro.sill` |
| Primary language | English (U.S.) |
| Category | Productivity (secondary: Utilities) |
| Price | Free |
| Content rights | Does not contain, show, or access third-party content |
| Age rating | Answer "None" to every question → 4+ |
| Privacy Policy URL | https://mrskiro.github.io/sill/privacy.html |
| Support URL | https://mrskiro.github.io/sill/support.html |
| Marketing URL | https://mrskiro.github.io/sill/ |
| Copyright | 2026 mrskiro |
| App Privacy | "Data Not Collected". Answer No to every collection question |
| Export compliance | `ITSAppUsesNonExemptEncryption` is `false` in the Info.plist, so Connect does not ask. See the note at the end |
| Trader status (EU DSA) | Non-trader |

## Version information

**Subtitle** (30 chars max)

> Local-first Markdown notes

**Promotional text** (170 chars, editable without a new build)

> No account, no server. Notes stay on your iPhone and sync directly with your Mac when the two are near each other.

**Description** (4000 chars max)

> Sill is a small notepad for things you want to put down quickly and find again later.
>
> Notes are plain Markdown and stay plain. No smart quotes, no auto-capitalization, no hidden formatting: what you type is what is stored, and you can copy any note out as text at any time.
>
> Everything lives on your iPhone in a single local database. There is no account to create and no server in between, so Sill opens instantly and works the same with or without a network.
>
> If you also use the free Sill app for Mac, pair the two once by scanning a QR code. From then on they sync directly whenever they are near each other, over your local network or peer-to-peer Wi-Fi, with mutual TLS between the two devices. Nothing passes through the internet. The Mac app is optional: Sill on iPhone is a complete notepad on its own.
>
> Lists that keep up: Return continues bullets, numbers and checkboxes.
>
> Quiet: no analytics, no ads, no notifications, no third-party SDKs. Sill collects no data at all.
>
> Sill is free and open source under the MIT license. Source code, issue tracker and the Mac app: github.com/mrskiro/sill

**Keywords** (100 chars max, comma-separated, no spaces after commas)

> markdown,notes,notepad,local,offline,privacy,sync,mac,plain text,checklist,open source

**What's New** (first version)

> First release.

## Review notes

Paste into "Notes" under App Review Information. The reviewer will not have a Mac.

> Sill is a standalone Markdown notepad. Creating, editing, listing and deleting notes all work on the iPhone alone with no account, no sign-in and no network.
>
> The Sync screen (toolbar button top-left) pairs the phone with the optional, free Sill app for macOS by scanning a QR code shown on the Mac. Without a Mac this screen simply shows the pairing instructions; nothing else in the app depends on it. The Local Network permission and the Bonjour service `_sill._tcp` exist only for that direct Mac-to-iPhone connection. No server is involved anywhere.
>
> The camera is used only to scan the pairing QR code.
>
> Sill collects no data. The privacy policy is linked from the Sync screen and at https://mrskiro.github.io/sill/privacy.html

Contact information in that section is the developer's own (name, phone, email). It is not shown publicly.

## Screenshots

`scripts/app-store-screenshots.sh` boots the iPhone 17 Pro Max simulator, seeds a few notes through the
autotest hook, and captures the 6.9" set (1320 × 2868) into `build/screenshots/`. Upload the PNGs as
they are; Connect scales them for smaller phones. Order:

1. Note list (Today / Yesterday / Previous 7 Days sections)
2. Editor with a Markdown checklist
3. Sync screen

## Uploading a build

The `ios` job in `.github/workflows/release.yml` runs on the same `vX.Y.Z` tag as the Mac release. It
archives `SillPhone` with manual signing, then `xcodebuild -exportArchive` with `destination: upload`
sends it to App Store Connect, authenticated by the existing ASC API key. The build number is the
workflow run number, so nothing about versions is committed. Processing takes a few minutes; the build
then appears under TestFlight and can be selected on the version page.

One-time setup, in addition to the Mac secrets:

| Secret | Where it comes from |
|---|---|
| `IOS_CERTIFICATE_P12` / `IOS_CERTIFICATE_PASSWORD` | Certificates › **Apple Distribution** (not Developer ID). Export from Keychain Access as .p12, base64-encode |
| `IOS_PROVISION_PROFILE` | Profiles › **App Store Connect** for `com.mrskiro.sill`, named **Sill App Store** (project.yml asks for that name). Download, base64-encode |

The app record (bundle ID `com.mrskiro.sill`) has to exist in App Store Connect before the first upload,
or it is rejected with "No suitable application records were found".

## Checklist before "Submit for Review"

- [ ] Build uploaded (`release.yml`, iOS lane) and selected on the version page
- [ ] Screenshots uploaded
- [ ] Privacy Policy URL, Support URL, App Privacy answered
- [ ] Age rating done
- [ ] Review notes pasted
- [ ] Trader status declared in the developer account (Business › Trader status)

## Export compliance note

`ITSAppUsesNonExemptEncryption: false` tells Connect not to ask about encryption. Sill uses TLS
through Network.framework (OS-provided) and generates its device certificate with swift-crypto, which
is a standard-algorithm implementation rather than Apple's. Apple's own guidance treats standard
algorithms as exempt from the questionnaire; whether a yearly self-classification report is owed is a
separate question that the developer decides, not this file.
