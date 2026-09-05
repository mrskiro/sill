# Sill

[![CI](https://github.com/mrskiro/sill/actions/workflows/ci.yml/badge.svg)](https://github.com/mrskiro/sill/actions/workflows/ci.yml)

思いついたものを、窓辺に一旦置くように書ける、小さなローカルファースト Markdown メモ。
macOS + iPhone、アカウント無し、近くにいるときだけ直接 P2P 同期。

設計: [docs/design.md](docs/design.md)

## Build / Test

```sh
xcode-select -p        # Xcode 26.6 以上を指していること（違えば sudo xcode-select -s /Applications/Xcode.app）
brew install xcodegen  # 一度だけ

make gen        # project.yml → Sill.xcodeproj（生成物。gitignore 済み）
make build      # macOS + iOS simulator
make test       # SillCore の swift test + Mac / iOS(simulator) アプリのホスト型テスト
make device-check DEVICE=<xcrun devicectl list devices の Identifier>   # ペア済み iPhone との実機同期を自動検証
make hygiene    # 公開リポジトリ向けの走査（個人のパス、メール、鍵、チーム ID、端末 UDID）
```

- `Packages/SillCore` は `swift test` で単体で回る（モデル、GRDB ストア、同期エンジン、編集ヘルパー）。
- `Tests/Mac` / `Tests/iOS` は Sill.app 内で動くホスト型テスト。`SILL_TEST_MODE=1` で使い捨て DB を使い、Mac ではパネルが key window にならないので他アプリへの入力を奪わない。
- 署名は `Configs/Local.xcconfig`（gitignore 済み）の `DEVELOPMENT_TEAM`。Mac も team 署名（data protection keychain に端末 identity を置くため）。初回は `-allowProvisioningUpdates -allowProvisioningDeviceRegistration` で profile が作られる（Makefile に含む）。
- ペアリング: Mac の Settings（⌘,）で「Pair iPhone…」→ iPhone の Sync 画面で QR をスキャン（またはコードを貼り付け）。
- Mac のキー: ⌥S 表示/非表示（Settings で変更可）、Esc 閉じる、⌘N 新規、⌘⇧C Markdown としてコピー、⌥⌘S サイドバー（フッター左のボタンでも開閉）、⌘⌫ 削除、⌘⇧P ピン（クリックで隠れない）、Return / Tab / ⇧Tab / ⌘Return でリスト操作。

## CI / Release

- CI（`.github/workflows/ci.yml`）: macOS 26 ランナーで hygiene 走査、SillCore の `swift test`、Mac / iOS simulator のビルド。署名と実機が要るホスト型テストはローカルの `make test` で回す。
- Release（`.github/workflows/release.yml`）: `vX.Y.Z` タグで Developer ID 署名 + 公証済みの Mac アプリを GitHub Release に添付する。Secrets（Developer ID 証明書、App Store Connect API キー、Team ID）を設定するまで動かない。詳細はワークフロー冒頭のコメント。
- Actions は SHA 固定を必須にしている。Dependabot が actions と SwiftPM を週次で更新する。

## License

MIT
