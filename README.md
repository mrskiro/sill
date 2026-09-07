# Sill

[![CI](https://github.com/mrskiro/sill/actions/workflows/ci.yml/badge.svg)](https://github.com/mrskiro/sill/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/mrskiro/sill?label=release)](https://github.com/mrskiro/sill/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A small local-first Markdown notepad for Mac and iPhone. No account, no server —
your devices sync directly when they are near each other.

[Website](https://mrskiro.github.io/sill/) · [日本語](README.ja.md)

## Install

**Mac** — download the disk image from the [latest release](https://github.com/mrskiro/sill/releases/latest)
and drag Sill to Applications. It is signed and notarized, so macOS will not refuse to
open it — the first launch still asks once whether to open an app downloaded from the
internet. Requires macOS 26 or later.

**iPhone** — not on the App Store yet. Build it from source and pair it from the
Mac's Settings.

## What it does

- **⌥S** opens a floating panel over whatever you are doing. **Esc** hides it.
- Notes live in a single SQLite file on the device. Nothing waits on a network.
- Plain Markdown in, plain Markdown out. No smart quotes, no auto-capitalization.
- Pair once, then your devices sync over mutual TLS whenever they can reach each
  other on the local network. Two Macs sync with each other as well.
- No menu bar icon and no background updater. It looks for updates only when asked.

Mac keys: **⌥S** show/hide (configurable), **Esc** close, **⌘N** new note,
**⌘⇧C** copy as Markdown, **⌥⌘S** sidebar, **⌘⌫** delete, **⌘⇧P** pin,
**Return / Tab / ⇧Tab / ⌘Return** for lists.

To pair, open Settings (⌘,) on the Mac and choose **Pair a Device…**. From an
iPhone, scan the QR code on its Sync screen; from another Mac, use **Copy Code**
and paste it into that Mac's Settings.

## Build

```sh
xcode-select -p        # must point at Xcode 26.6 or later
brew install xcodegen  # once

make gen               # project.yml -> Sill.xcodeproj (generated, gitignored)
                       # it also creates Configs/Local.xcconfig from the example
$EDITOR Configs/Local.xcconfig   # put your own DEVELOPMENT_TEAM in it, or signing fails
make build             # macOS + iOS simulator
make test              # SillCore unit tests + hosted tests for both apps
```

`Configs/Local.xcconfig` is gitignored. The Mac app is team-signed even locally,
because the device identity lives in the data-protection keychain.

## Contributing

Issues and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) has the
workflow and the conventions; [SECURITY.md](SECURITY.md) has how to report a
vulnerability. The architecture and the reasoning behind it live in
[docs/design.md](docs/design.md).

## License

MIT © 2026 mrskiro
