# Contributing

Thanks for looking. Sill is a small app on purpose, so the most useful thing you can
do before writing code is open an issue and say what you are trying to solve.

## Getting set up

```sh
xcode-select -p        # must point at Xcode 26.6 or later; if it points at
                       # CommandLineTools: sudo xcode-select -s /Applications/Xcode.app
brew install xcodegen  # once

make gen               # project.yml -> Sill.xcodeproj (generated, gitignored).
                       # It also creates Configs/Local.xcconfig from the example.
```

Put your own `DEVELOPMENT_TEAM` in `Configs/Local.xcconfig` before building — the
generated copy carries a placeholder, and `make build` fails to sign without it. The
file is gitignored. The Mac app is team-signed even for local builds: the device
identity lives in the data-protection keychain, which needs an `application-identifier`
entitlement, and the first build creates the profile for you.

## Running the tests

```sh
make test   # SillCore unit tests, then the hosted tests for both apps
make lint   # swift-format, configured by .swift-format (make format rewrites)
```

- `Packages/SillCore` runs standalone with `swift test` — model, GRDB store, sync
  engine, editing helpers. The sync engine is pure functions, and convergence is
  checked by simulating several devices over random operation sequences.
- `Tests/Mac` and `Tests/iOS` are hosted tests that run inside Sill.app. They set
  `SILL_TEST_MODE=1`, which uses a throwaway database and keeps the Mac panel from
  becoming the key window, so running them does not steal your keystrokes.
- `make device-check DEVICE=<id>` is separate from `make test`. It drives a real paired
  iPhone end to end; get the id from `xcrun devicectl list devices`, and unlock the
  phone first.

Both apps append to `Application Support/Sill/sync.log`, which is the first place to
look when sync misbehaves. On the Mac it is in your own container; from an iPhone,
pull it with:

```sh
xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
  --domain-identifier com.mrskiro.sill \
  --source "Library/Application Support/Sill/sync.log"
```

The log names your devices and carries the first characters of pairing codes, so read
it before pasting it anywhere public.

## Sending a change

Fork the repository, push your branch there, and open a pull request against `main`.
`main` is protected, so a pull request is the only way in; once CI is green it gets
squash merged.

Before you push, run `make lint`. Keep personal paths, email addresses, keys, team ids
and device identifiers out of the repository — the history is public and cannot be
edited afterwards — and apply the same standard to commit messages, pull request
bodies and issues.

A few conventions worth knowing:

- **Minimal first.** Prefer the simplest thing that satisfies the requirement, and
  check the decisions table in `docs/design.md` before adding a feature.
- **UI strings are English**, including month and date formats, which are pinned so
  they do not follow the locale.
- Comments go above an attribute, never at the end of the line — swift-format rejects
  the latter.

## Where things are

`docs/design.md` is the architecture and, more usefully, the record of what was decided
and why: the sync model, the pairing scheme, the merge rules, and the things
deliberately left out. `docs/app-store.md` holds what goes into App Store Connect for
the iPhone app. `CLAUDE.md` is a short working guide with the traps this codebase has
already hit.

CI (`.github/workflows/ci.yml`) runs the lint, `swift test` and a build of both apps on
a macOS runner, with signing disabled. The hosted tests need a signing identity, so
they stay local — `make test` itself runs on your Mac and a simulator, not a phone.

Pushing a `vX.Y.Z` tag runs two release jobs. The macOS one signs with a Developer ID,
notarizes both the app and the disk image, staples both, verifies the result and
attaches it to a GitHub release. The iOS one archives with Apple Distribution and
uploads to App Store Connect, where the build shows up in TestFlight; releasing it to
the store stays a manual step there. Each job needs its own secrets, so a fork without
them cannot cut a release.
