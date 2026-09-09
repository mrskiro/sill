# App Store submission (iPhone)

What goes into App Store Connect for the iOS app, so it can be pasted rather than composed
under pressure. The Mac app stays on Developer ID (`docs/distribution.md`); this is iPhone only.

## App record

| Field | Value |
|---|---|
| Name | Sill Notes ("Sill" alone is taken by an unpublished app; the home-screen name stays Sill via `CFBundleDisplayName`) |
| Bundle ID | `com.mrskiro.sill` |
| App ID | 6809280142 (the `--app` for `asc`) |
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

The copy lives in `metadata/` in the layout `asc` (App Store Connect CLI) reads, so it is applied
rather than pasted: `metadata/app-info/en-US.json` holds the name, subtitle and privacy policy URL;
`metadata/version/<version>/en-US.json` holds the description, keywords, promotional text, support and
marketing URLs. Add `whatsNew` from the second version on; Apple rejects it on the first, and one rejected
field fails the whole localization update. The version directory has to match the App Store version being
prepared (rename it when the first store version is not 0.2.0).

```sh
asc metadata validate --dir metadata                                   # offline, limits and shape
asc metadata apply --app 6809280142 --version 0.2.0 --dir metadata --dry-run
asc metadata apply --app 6809280142 --version 0.2.0 --dir metadata
```

Limits: subtitle 30, promotional text 170, description 4000, keywords 100 characters.

## Review notes

Paste into "Notes" under App Review Information (`asc review details-update --id <DETAIL_ID> --notes`).
The reviewer will not have a Mac. The first submission came back with a "Guideline 2.1 Information
Needed" request, which every new developer account gets: a screen recording from a physical iPhone
plus answers to six standard questions. The notes now carry those answers so later submissions do not
have to repeat them; the recording is attached to the review detail.

> Sill is a small, free, open-source Markdown notepad. There is no account, no sign-in, no server, no in-app purchase and no user-generated content shared between users. Creating, editing, listing and deleting notes all work on the iPhone alone.
>
> 1. Screen recording: see the attachment (recorded on an iPhone running the current iOS). It starts from launching the app and shows writing a note with a Markdown checklist, returning to the list, and the Sync screen. No registration, login, account deletion, content reporting or paid content exists in the app.
>
> 2. Purpose and audience: a personal notepad for quickly writing thoughts down as plain Markdown and finding them again. It is for people who want plain-text notes kept on their own devices with no account and no cloud. Its value is speed (it opens directly on the last note), text preservation (nothing rewrites the Markdown) and privacy (data never leaves the user's devices).
>
> 3. Setup and access: nothing to set up. Launch the app and type; notes save automatically. The pencil button makes a new note and the back button returns to the list. The Sync screen (top-left button) is optional: it pairs the iPhone with the free companion app for macOS from the same developer (distributed outside the App Store, github.com/mrskiro/sill) by scanning a QR code shown on the Mac, after which the two devices exchange notes directly over the local network. Without a Mac the screen only shows the pairing instructions; everything else works. No credentials or sample files are needed.
>
> 4. External services: none. The app has no backend, analytics, advertising, authentication, payment or AI services. It uses Apple frameworks only (SwiftUI, UIKit, Network.framework with Bonjour for the local Mac connection, VisionKit to scan the pairing QR code, Keychain) plus two open-source libraries compiled into the binary: GRDB (local SQLite database) and swift-certificates / swift-crypto (the device certificate for the direct connection). The only destination outside the user's own devices is GitHub, and only when the user taps "Report an Issue", which opens the issue tracker in Safari.
>
> 5. Regional differences: none. The app behaves identically in every region; the interface is English only.
>
> 6. Regulated industry or protected third-party material: not applicable. The app contains no third-party content and is MIT-licensed open source at github.com/mrskiro/sill.
>
> The Local Network permission and the Bonjour service _sill._tcp exist only for the direct Mac-to-iPhone connection. The camera is used only to scan the pairing QR code. Privacy policy: https://mrskiro.github.io/sill/privacy.html
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

- [x] App record created in App Store Connect (browser; the public API cannot create apps)
- [x] Build uploaded (`release.yml`, iOS lane) and selected on the version page (`asc versions attach-build`)
- [x] `asc metadata apply` run for the version
- [x] Screenshots uploaded (`asc screenshots upload --device-type IPHONE_69`)
- [ ] App Privacy answered (`asc validate --check-urls` confirms the URLs resolve)
- [x] Age rating done (`asc age-rating edit --all-none`), categories, content rights, price and availability set with `asc`
- [x] Review notes set (`asc review details-create`)
- [x] Contact name, phone and email under App Review Information, and untick "Sign-in required" (the API created the record with it on; changing it needs the contact fields)
- [x] App Privacy published (Data Not Collected). Not reachable through the public API
- [ ] Trader status declared in the developer account (Business › Trader status)

## Export compliance note

`ITSAppUsesNonExemptEncryption: false` tells Connect not to ask about encryption. Sill uses TLS
through Network.framework (OS-provided) and generates its device certificate with swift-crypto, which
is a standard-algorithm implementation rather than Apple's. Apple's own guidance treats standard
algorithms as exempt from the questionnaire; whether a yearly self-classification report is owed is a
separate question that the developer decides, not this file.

## Submitting

`asc validate --app 6809280142 --version <version> --check-urls` with zero errors, then:

```sh
asc versions attach-build --version-id <VERSION_ID> --build-id <BUILD_ID>
asc review submit --app 6809280142 --version <version> --build-id <BUILD_ID> --confirm
asc review status --app 6809280142
```

0.2.0 (build 10) was submitted this way on 2026-09-07 and is waiting for review. The App Store profile
"Sill App Store" (`asc profiles create --profile-type IOS_APP_STORE`) and the Apple Distribution
certificate both expire 2027-09-07.
