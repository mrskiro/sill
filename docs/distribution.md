# 配布（Mac）

`vX.Y.Z` タグを push すると `.github/workflows/release.yml` が Developer ID 署名 + 公証済みの dmg を
GitHub Release に添付する。v0.1.0 は zip、v0.1.1 以降は dmg。

## 決定と理由

| # | 決定 | 理由 |
|---|---|---|
| 1 | Mac App Store ではなく Developer ID 直配布（将来 brew tap） | 無料の公開 OSS。App Store の事務（privacy manifest、DSA trader 申告、輸出コンプラ審査）が丸ごと不要になる |
| 2 | export は**手動署名**（cloud signing を使わない） | cloud signing は Developer ID の provisioning profile を発行できない。Team Key の Admin でも `Cloud signing permission error` で拒否される |
| 3 | provisioning profile を secret で持つ | entitlement に `keychain-access-groups` があるので `application-identifier` が要り、それは profile からしか来ない。**普通の Developer ID アプリはこれを踏まない**（`stablyai/orca` の macOS entitlements にも該当なし） |
| 4 | zip ではなく dmg | zip を `~/Downloads` に置いたまま起動すると App Translocation でランダムな読み取り専用パスから動く。dmg の `/Applications` へのリンクはそのドラッグを促す作法で、ドラッグ時に quarantine が外れる。brew cask で最も一般的な形式でもある |
| 5 | **アプリと dmg の両方**を公証して staple | dmg だけだと、ドラッグして取り出したアプリはチケットを持たず初回起動にオンライン確認が要る。チケットはアーカイブに貼れないので、アプリ用の submit では zip を封筒として使う |
| 6 | 自動更新機構は持たない | Sill メニューの Check for Updates が、押したときだけ `releases/latest` を1回見る。Sparkle はバイナリフレームワーク + XPC + entitlement 例外 + CI の署名鍵を背負うので、この規模では割に合わない |

## 落とし穴

- **証明書と秘密鍵が別のキーチェーンにあると、Keychain Access の「自分の証明書」に出ない。**
  identity は検索リストをまたいで組み立てられるので `security find-identity -v -p codesigning` では見えるが、
  GUI は同じキーチェーンで組めるものしか出さない。結果、`.p12` の書き出しで別の証明書（Apple Development）を
  選んでしまう。キーチェーンごとに `security find-identity -v -p codesigning <keychain>` を見て確認し、
  証明書を login にコピー（`security find-certificate -c "..." -p <src> | security import /dev/stdin -k login.keychain-db`）すれば揃う。
- **`PROVISIONING_PROFILE_SPECIFIER` を xcodebuild のコマンドラインで渡してはいけない。**
  全ターゲットに適用されるので、SwiftPM の依存（GRDB、swift-crypto、KeyboardShortcuts）が
  `does not support provisioning profiles` で落ちる。手動署名は export options plist 側でやる。
  archive まで手動署名にしたい場合は `project.yml` の Release 設定に入れる必要がある。
- `spctl -t install` は**インストーラパッケージ**の評価タイプ。アプリは `--type execute`（`spctl(8)`）。
- 空の secret は `SecKeychainItemImport: One or more parameters passed to a function were not valid` になる。
  ワークフローはキーチェーン構築の直後に「空でないか」と「Developer ID identity が実在するか」を検証して数秒で止まる。
- Keychain Access の書き出しの既定ファイル名は `証明書.p12`。パスを決め打ちしたスクリプトは空振りする。

## 期限のあるもの

| 対象 | 期限 | メモ |
|---|---|---|
| Developer ID Application 証明書 | 2027-02-01 | 発行元 G1 の期限に揃っている。更新すると発行元は G2 になる。ワークフローは G1 / G2 両方の中間証明書を入れてある |
| Developer ID provisioning profile | 2044-09-01 | 作り直しても名前・UUID をワークフローに書く必要はない（ファイルから読む） |

## Secrets

| 名前 | 中身 |
|---|---|
| `APPLE_TEAM_ID` | 10 文字のチーム ID |
| `MACOS_CERTIFICATE_P12` / `MACOS_CERTIFICATE_PASSWORD` | Developer ID Application 証明書 + 秘密鍵（base64）とそのパスワード |
| `MACOS_PROVISION_PROFILE` | Developer ID の `.provisionprofile`（base64）。機密ではない |
| `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_API_KEY_P8` | App Store Connect API キー。**現状 Admin ロールが要る**（archive が cloud signing で開発用 profile を取るため）。archive も手動署名にすれば公証専用に落とせる |

`ci.yml` は secret を1つも参照しない。`release.yml` は `v*` タグの push でしか起動せず、fork の PR に secret は渡らない。

## リリース後の確認

公開された成果物そのものを落として確かめる（CI のログではなく）:

```sh
gh release download vX.Y.Z --repo mrskiro/sill --dir /tmp/verify && cd /tmp/verify
shasum -a 256 -c *.sha256
xcrun stapler validate Sill-X.Y.Z.dmg
hdiutil attach -quiet -nobrowse -mountpoint mnt Sill-X.Y.Z.dmg
spctl -a -vvv --type execute mnt/Sill.app   # accepted / source=Notarized Developer ID
xcrun stapler validate mnt/Sill.app         # 取り出したアプリもチケットを持つこと
hdiutil detach -quiet mnt
```
