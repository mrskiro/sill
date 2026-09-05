# Sill

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
