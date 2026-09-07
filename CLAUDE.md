# Sill — 作業規約（Claude Code 向け）

設計と現状は `docs/design.md`。ここは「どう作業するか」だけ。

## 原則

- ミニマル最優先。MVP 要件を満たす最も単純な案を選び、機能を足す前に設計書の決定事項を確認する。
- 公開リポジトリ前提。個人のパス、メール、チーム ID、端末 UDID、環境固有の値を追跡ファイルに入れない。公開後の履歴は消せないので、コミット前に自分の目で見る。
- 同じ基準を PR 本文・コミットメッセージ・Issue にも適用する。とくに claude.ai のアーティファクト / セッション URL は他人が開けないため載せない（必要な内容はリポジトリ内に書く）。ローカルパスやワークツリー名も同様。
- UI 文言は英語で統一（ロケール依存の月名・日付も英語固定）。
- 自己レビューはしない。品質判断が要るときは `/review`（Codex + ペルソナ）にかける。
- main へ直接 push しない（`.claude/hooks` がブロック）。ブランチ → PR → CI 緑 → squash merge。

## ビルド / テスト

- `make gen` で `Sill.xcodeproj` を生成（XcodeGen、生成物は gitignore）。ファイル追加は syncedFolder なので再生成不要。
  ただし新しい *ディレクトリ*（`Assets.xcassets` など）は DerivedData のビルド記述に載らず黙って無視される。`rm -rf ~/Library/Developer/Xcode/DerivedData/Sill-*` してから `make gen`。
- `make icons` で両 `Assets.xcassets` を `scripts/make-app-icon.swift` から描き直す（幾何はスクリプト内の定数が正）。
- `make test` = `swift test`（SillCore）+ Mac ホスト型 + iOS simulator ホスト型。`make lint` は swift-format（`.swift-format`）。
- 実機: `make device-check DEVICE=<id>`（`xcrun devicectl list devices`）。iPhone はロック解除が必要。Mac アプリを `SILL_DEBUG=1` で起動して `sill://debug/...` を使う。
- 両アプリは `Application Support/Sill/sync.log` に同期の経過を残す。iPhone 側は `xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier com.mrskiro.sill --source "Library/Application Support/Sill/sync.log"` で取れる。

## リリース

- `vX.Y.Z` タグを push すると `.github/workflows/release.yml` が Developer ID 署名 + 公証済みの dmg を Release に添付する。
- export は**手動署名**。cloud signing は Developer ID の provisioning profile を発行できない（Admin の API キーでも `Cloud signing permission error`）。profile が要るのは `keychain-access-groups` が `application-identifier` を要求するためで、普通の Developer ID アプリはここを踏まない。profile は secret から復元し、UUID はファイル自身から読む。
- アプリと dmg の**両方**を公証して staple する。dmg だけだと、そこから取り出したアプリはチケットを持たず、オフラインで初回起動できない。
- 配布を zip にしない。`~/Downloads` に置いたまま開くと App Translocation でランダムな読み取り専用パスから動く。dmg の `/Applications` リンクへのドラッグが quarantine を外す。
- 署名証明書を更新すると発行元が G1 → G2 に変わる。ワークフローは両方の中間証明書を入れてある。

## 落とし穴

- `xcode-select -p` が CommandLineTools を向いている環境では、`DEVELOPER_DIR` に Xcode 26.6 以上の `Contents/Developer` を渡すか `sudo xcode-select -s <Xcode.app>` する。
- ホスト型テストは `SILL_TEST_MODE=1`（使い捨て DB、Mac はパネルが key にならず accessory ポリシー）。osascript でキー入力を送らない（Accessibility 権限が無く、ユーザーの入力を奪う）。
- Mac のテストバンドルに `SillMac` パッケージ製品を直接リンクさせない（Xcode の package framework 生成で失敗する）。ホストアプリのモジュールを使う。
- Mac の署名は team 署名 + `keychain-access-groups`（data protection keychain）が必要。`-allowProvisioningUpdates -allowProvisioningDeviceRegistration` は Makefile に入っている。Xcode のアカウントが "rejected" になったら Xcode › Settings › Accounts で再サインイン。
- Bash サンドボックスは `~/Library` や SwiftPM の一時領域、ネットワーク（gh、push、pkgx）を遮るので、ビルド・テスト・GitHub 操作はサンドボックス外で実行する。
- 並行して動く Homebrew メンテナンスが `xcodegen` を消したことがある。`brew install xcodegen` で戻す。
- NSTextView の undo は連続入力を 1 まとめにする AppKit 標準の粒度。テストで 1 手ずつは戻らない。
- swift-format は属性行末のコメントを嫌う。コメントは属性の上に置く。
- `PROVISIONING_PROFILE_SPECIFIER` を xcodebuild のコマンドラインで渡さない。全ターゲットに効くので SwiftPM の依存が `does not support provisioning profiles` で落ちる。手動署名は export options plist 側で指定する。
- 証明書と秘密鍵が別のキーチェーンにあると、identity は `security find-identity` では見えるのに Keychain Access の「自分の証明書」には出ない（GUI は同じキーチェーンで組めるものだけを出す）。`.p12` を書き出す前にキーチェーンごとに `security find-identity -v -p codesigning <keychain>` で確認する。
- `spctl` でアプリを評価するときは `--type execute`。`-t install` はインストーラパッケージ用で、別のポリシーを見ることになる。
