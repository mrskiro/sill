# Sill — 最小アーキテクチャ（MVP 設計 v1）

状態: v1 確定（2026-09-04）。判断基準は「MVP 要件を満たす最も単純な案」。変更は末尾の決定事項表を更新して残す。

## 前提（2026-09-04 時点で確認済みの事実）

| 項目 | 事実 | 出典 |
|---|---|---|
| MultipeerConnectivity | Xcode 27 でフレームワーク全体が deprecated | Apple TN3213 |
| Network.framework 新 API | `NetworkListener` / `NetworkBrowser` / `NetworkConnection` / `TLS` / `Coder` は iOS 26 / macOS 26 以降 | Apple Developer Documentation |
| Peer-to-Peer Wi-Fi (AWDL) | 新 API は `.parameters { … }.peerToPeerIncluded(true)` で opt-in。共有 Wi-Fi 不要 | TN3213 |
| TLS-PKI（新 API） | `TLS().peerAuthentication(.required).localIdentity(sec_identity).certificateValidator { … }` で相互 TLS。ローカルで証明書を作る Apple API は無く、Apple は swift-certificates を挙げている | TN3213 |
| TLS-PSK | 旧 API 限定・TLS 1.2 限定。不採用 | TN3213、DevForums 688508 |
| SecIdentity の作成 | 証明書と秘密鍵を Keychain に追加し（鍵の `kSecAttrApplicationLabel` = 証明書の `kSecAttrPublicKeyHash`）、`kSecClassIdentity` で取り出す。EC 鍵推奨。macOS は `kSecUseDataProtectionKeychain` | DevForums 773016 / 773777（Quinn） |
| swift-certificates | v1.20.0（2026-09-01）。依存: swift-crypto、swift-asn1。tools 6.1 | GitHub |
| Local Network privacy | macOS 15+ / iOS 14+ で `NSLocalNetworkUsageDescription` と `NSBonjourServices` が必要 | Apple TN3179 |
| GRDB.swift | v7.11.1（2026-06）。Swift 6.1+ / Xcode 16.3+ | GitHub |
| KeyboardShortcuts | v3.0.1（2026-06）。Carbon hotkey ラッパー、Accessibility 権限不要 | GitHub |
| XcodeGen | v2.46.0（2026-07） | GitHub |
| Raycast Notes の UX | 1 画面 1 ノート、サイドバー無し。⌘N 新規、⌘P で Browse（ノート一覧ポップアップ）、⌘[ / ⌘] で履歴移動、⇧⌘P ピン、⌘0-9 ピン済みへ移動、先頭行がタイトル | Raycast Manual |
| Apple メモ | Dock アプリ（メニューバーアイコン無し）。サイドバー + エディタ。Quick Note（Fn+Q / ホットコーナー）で小さな浮くウィンドウ | macOS 標準 |

Deployment target は macOS 26 / iOS 26。新 Network API が要るのでこれ以下にはできない。

## 優先順位（仕様より）

1. Speed  2. Low cognitive friction  3. Local-first  4. Text preservation  5. Markdown interoperability  6. Minimalism

ただし「将来プロダクトとしてリリースする」を前提に、**セキュリティと同期モデルは標準的で台数が増えても崩れない形**を最初から選ぶ。UI と機能は MVP 最小のまま。

---

## 1. 全体アーキテクチャ

```
┌──────────────── macOS app (SillMac) ───────────────┐   ┌──────────── iOS app (SillPhone) ───────────┐
│ Dock app + hotkey + NSPanel(floating) + QR 表示     │   │ NavigationStack + UITextView + QR scan      │
│ role: listener + dialer（Mac 同士は id で決める）   │   │ role: browser + connect (client)            │
└───────────────┬────────────────────────────────────┘   └───────────────┬────────────────────────────┘
                │ depends on                                              │ depends on
┌───────────────▼──────────────────────────────────────────────────────────▼────────────────────────────┐
│ SillCore (SwiftPM, platform neutral, `swift test` で回る)                                              │
│  Model  Store(GRDB)  Sync(engine: 純関数)  Identity(cert/keychain)  Transport(Network.framework)      │
│  Editing(純関数)                                                                                       │
└───────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

- UI は常にローカル DB を読む（GRDB `ValueObservation` → SwiftUI）。ネットワークを待つ経路はゼロ。
- 書き込みは `NoteStore` の 1 か所に集約（ユーザー編集・同期適用・競合解決のすべて）。
- Sync engine は「ローカル状態 + 受信メッセージ → 書き込み命令」の純関数として書き、ネットワーク無しで複数端末をシミュレートしてテストする。

## 2. 1 project + macOS/iOS 2 target

- `Sill.xcodeproj` を **XcodeGen (`project.yml`)** から生成。pbxproj を手で編集しない。生成物は gitignore。
- target は 2 つ（macOS app / iOS app）。単一 multiplatform target は採らない。理由: Info.plist キー、AppKit ライフサイクル、entitlements が macOS 専用で `#if os()` が UI 全体に散る。
- 共有ロジックはすべて `Packages/SillCore` に置き、app target は薄く保つ。
- Tuist は不採用（target 2 つに Swift 製マニフェストとキャッシュは要らない）。

## 3. Local Persistence: GRDB.swift（SQLite）

| 基準 | GRDB |
|---|---|
| 起動速度 | SQLite open のみ |
| local-first | 単一ファイル。全部こちらの管理下 |
| 差分同期 | 「相手が未見のバージョン」の範囲クエリと、適用 + ベクトル更新を 1 トランザクションで書ける |
| migration | `DatabaseMigrator` に生 SQL |
| 依存の少なさ | SPM 依存 1 つ。CloudKit / Core Data と無関係 |
| デバッグ | `sqlite3 sill.sqlite` で直接見られる。将来の MCP も同じファイルを読める |

比較した選択肢（記録用、2026-09-04 時点）:

| 系統 | 候補 | 評価 |
|---|---|---|
| ファイルそのもの | 単一 JSON ファイル + メモリ内配列（atomic write） | 依存ゼロで最小。保存のたびに全件書き直し、部分更新不可、他プロセスからの読み取りと将来の FTS に弱い。MVP 規模なら動くが、データが増えた時に置き換えになる |
| | ノート 1 件 = 1 ファイル | 書き込み単位は良いが、列挙とメタデータ索引を自前で持つことになる |
| | UserDefaults / plist | 設定用。本文に使うものではない |
| Apple 純正 | SwiftData | SwiftUI 統合は最も楽だが、裏は Core Data。生 SQL・トランザクション制御が無く、同期メタデータの扱いが不透明。iCloud 前提の設計思想 |
| | Core Data | 成熟しているが重い。FTS 無し |
| SQLite 系 | **GRDB**（採用） | 薄い、migration と観測がある、Swift 6 対応、FTS5 の逃げ道 |
| | SQLiteData（Point-Free、1.12.0） | GRDB の上に SwiftData 風 API + CloudKit 同期。層が一つ増える |
| | Blackbird | Swift concurrency 前提の薄いラッパー。小さいが個人メンテ・リリースタグ無し |
| | SQLite.swift（0.16.0） | 型安全 DSL の老舗。観測と migration が弱い |
| | 生 sqlite3 C API | 依存ゼロだが unsafe ラッパーを自前で持つ |
| 別種の DB | Realm | 2025-09-30 に MongoDB がサポート終了。不採用 |
| | Couchbase Lite（4.1.0） | 文書 DB + 独自 sync。企業向けで重い |
| | Boutique（3.0.2） | Codable 配列をメモリ + ディスクに置く小さなストア。「単一 JSON」のライブラリ版 |

Sill の要件で実際に競るのは「単一 JSON ファイル」と GRDB の 2 つ。GRDB を採る理由は、autosave がノート 1 行の書き込みで済む、WAL でクラッシュに強い、「同期適用 + ベクトル更新」を 1 トランザクションにできる、`sqlite3` CLI や将来の MCP から読める、の 4 点。代償は依存 1 つと schema 50 行。

DB パス: macOS `~/Library/Application Support/Sill/sill.sqlite`、iOS はアプリコンテナ内。WAL、`DatabaseQueue`。

```sql
CREATE TABLE note (
  id             TEXT PRIMARY KEY,      -- UUID
  content        TEXT NOT NULL,
  created_at     REAL NOT NULL,         -- unix seconds
  updated_at     REAL NOT NULL,
  deleted_at     REAL,                  -- tombstone
  origin_device  TEXT NOT NULL,         -- この状態を書いた端末
  origin_seq     INTEGER NOT NULL       -- その端末での通し番号。(origin_device, origin_seq) = この行の version
);
CREATE INDEX note_origin ON note(origin_device, origin_seq);

CREATE TABLE device (                   -- 自分。1 行
  id TEXT PRIMARY KEY, name TEXT NOT NULL
);

CREATE TABLE seen (                     -- version vector。自分の行も含み、自分の書き込みカウンタを兼ねる
  device_id TEXT PRIMARY KEY, max_seq INTEGER NOT NULL
);

CREATE TABLE peer (                     -- 信頼済み端末
  id TEXT PRIMARY KEY, name TEXT NOT NULL, cert_fingerprint BLOB NOT NULL, paired_at REAL NOT NULL, last_sync_at REAL
);
```

`Note` の Swift 表現は仕様どおり `id / content / createdAt / updatedAt / deletedAt`。仕様の `version` は `(origin_device, origin_seq)` に置き換える。`title` は先頭行から導出。`pinned` は持たない。秘密鍵と証明書は DB ではなく Keychain。

## 4. Markdown Editor

- 真実は `String` 1 本。AST も独自フォーマットも持たない。
- macOS: `NSTextView`（TextKit 2）を `NSViewRepresentable` で包む。iOS: `UITextView` を `UIViewRepresentable` で包む。
- SwiftUI `TextEditor` を使わない理由: 日本語 IME の変換確定と Return / Tab を区別するフックが無い。`NSTextView.insertNewline(_:)` / `insertTab(_:)` / `cancelOperation(_:)` の override は IME 確定後にだけ呼ばれる。
- Text preservation の必須設定: smart quotes / smart dashes / text replacement / auto-capitalization を OFF、`isRichText = false`。
- 編集ヘルパーは `SillCore/Editing` の純関数 `(text, selectedRange) -> (text, selectedRange)` として両 OS で共有・テスト:
  - Return: `- ` `* ` `1. ` `- [ ] ` を継続。空の項目で Return → マーカーを消す
  - Tab / Shift+Tab: リスト項目のインデント / アウトデント
  - ⌘Return: 現在行の `[ ]` ↔ `[x]` トグル（Raycast Notes と同じキー）
- シンタックスハイライトは MVP に入れない。
- フォント: システムフォント 14pt。

## 5. macOS: Dock アプリ + hotkey + Floating Window

- 形態: **Dock アプリ（通常の activation policy）**。メニューバーアイコンは置かず、同期状態はウィンドウ内フッターに小さく出す。Apple メモと同じ入口（Dock / ⌘Tab）に、Raycast Notes と同じ hotkey の入口を足す。
- ウィンドウは 1 つだけ。`NSPanel` サブクラス:
  - `styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable, .closable]`、タイトルバー透明
  - `isFloatingPanel = true`, `level = .floating`, `collectionBehavior = [.moveToActiveSpace, .managed, .fullScreenAuxiliary]`（`canJoinAllSpaces` は Mission Control から除外されるので使わない）, `hidesOnDeactivate = false`, `isMovableByWindowBackground = true`
  - hotkey からは `nonactivatingPanel` の性質でアプリを activate せずに key にする。前面アプリはそのまま。Esc で `orderOut` + 必要なら `NSApp.hide` でフォーカスを戻す
  - Dock クリック（`applicationShouldHandleReopen`）でも同じパネルを出す
- 中身は `NSHostingView`（SwiftUI）。エディタ部分だけ `NSViewRepresentable`。
- 挙動: hotkey でトグル、Esc で隠す、外をクリックしたら隠す（pin 中は隠さない）。pin = 常に最前面 + 自動で隠れない。位置・サイズは autosave。
- hotkey / Dock で開くのは **最後に編集したノート**。⌘N で新規。新規ノートは最初の非空白文字が入るまで DB に insert しない。
- 通常アプリでも hotkey 経由はアプリが inactive のまま key window になるので、⌘C / ⌘V / ⌘Z は `NSApp.mainMenu` の Edit メニューで拾う（SwiftUI `App` の標準メニューで足りる）。
- 表示レイテンシは `os_signpost` で計測し、hotkey → 入力可能まで 100ms 未満。

## 6. Global Shortcut

- `KeyboardShortcuts`（sindresorhus, v3.0.1）。Carbon `RegisterEventHotKey` ラッパー、Accessibility 権限不要、recorder view 込み。
- 既定値 **⌥S**。Settings から変更可（後回し）。

## 7. Transport（Network.framework 新 API）

- 役割: **Mac = `NetworkListener`（server）+ 必要なら `NetworkBrowser` / `NetworkConnection`（client）、iPhone = client のみ**。iPhone は advertise しないので、Mac ↔ iPhone は従来どおり client-server で dedup が要らない。
- **Mac 同士**は両方が listener でもあり client でもあるので、放っておくと互いに 1 本ずつ張って round が二重に走る。`SyncRole`（`Sync/SyncRole.swift`）で **device id（UUID 文字列）の小さい方が dial する**と決める。状態を持たず、両端が同じ答えに着くので折衝が要らない。ペアリングだけはこの規則を無視して、コードを貼った側が 1 回 dial する（その後 round を 1 巡してから、規則が指す側に dial を譲る）。
- 3 台以上の Mac では「自分より大きい id のうち最初に見つけた 1 台」に繋ぐだけなので、接続グラフは連結とは限らない（2 台 + iPhone は常に連結）。台数が増えたら peer ごとに dial タスクを持つ形にする。
- Mac は起動中ずっと `.bonjour(type: "_sill._tcp", txtRecord: [fp: 証明書 fingerprint 先頭 8 byte])` を advertise。サービス名は端末名ではなくランダム（TN3213 の privacy 指針）。dial する側の Mac は同じ TXT を見て相手を選ぶ（`MacDialer`）。
- iPhone は foreground かつ未接続の間 browse を続け、TXT の `fp` が信頼済み Mac に一致する endpoint が現れたら **browse を止めてから** connect。Mac を後から起動しても iPhone 側が見つける。
- 接続は iPhone が foreground の間維持。background で切れたら foreground 復帰時に再接続（指数バックオフ）。
- **Mac 起点の同期**: 接続中、Mac に新しい変更が出るたび（autosave 後 1 秒デバウンス）`poke` を送り、iPhone に round（9 節）を始めさせる。「Sync now」も同じ `poke`。iOS の制約上、Mac 発の同期が成立しうるのは iPhone 側アプリが前面の時だけで、その時は必ず接続が開いている。
- プロトコルスタック（両側同じ）:

```swift
.parameters {
    Coder(SyncMessage.self, using: .json) {      // 長さ付きフレーミング + Codable を Network.framework に任せる
        TLS()
            .peerAuthentication(.required)       // 相互 TLS
            .localIdentity(myIdentity)            // 8 節
            .certificateValidator { metadata, trust in
                // 相手の leaf 証明書の SHA-256 が信頼済み peer の fingerprint と一致するか。
                // ペアリングモード中の Mac だけは未知の fingerprint も通し、pair メッセージで検証する
            }
    }
}
.peerToPeerIncluded(true)
```

- Info.plist（両 OS）: `NSLocalNetworkUsageDescription`、`NSBonjourServices = ["_sill._tcp"]`。

## 8. Device Identity と Pairing（B: 自己署名証明書 + fingerprint pinning）

決定理由: 将来プロダクトとして出すときに、Apple が TN3213 で示す本線（TLS 1.3 相互認証）に最初から乗せる。forward secrecy もこちらだけが持つ。

**端末 identity（初回起動時に 1 回）**

1. `P256.Signing.PrivateKey()` を生成
2. swift-certificates（`X509`）で自己署名証明書を作る。subject/issuer = `CN=<deviceId>`、有効期間 10 年、`ecdsaWithSHA256`
3. 証明書を `SecItemAdd`（`kSecClassCertificate`, `kSecValueRef`）、鍵を `SecKeyCreateWithData(x963)` → `SecItemAdd`（`kSecAttrApplicationLabel` = 証明書の `kSecAttrPublicKeyHash`）。macOS は `kSecUseDataProtectionKeychain = true`
4. `SecItemCopyMatching(kSecClassIdentity)` で `SecIdentity` を得て `sec_identity_create` で TLS に渡す
5. `deviceId` = UUID、`fingerprint` = SHA-256(証明書 DER)

**ペアリング（QR は片方向、1 回）**

1. Mac の Settings → Pair a Device: one-time `token`（128 bit、2 分有効）を作り、`{v:1, deviceId, name, fingerprint, token}` を QR 表示（CoreImage）。Mac は「ペアリングモード」に入る
2. iPhone が VisionKit `DataScannerViewController` で読み取り、Mac を `peer` に保存（fingerprint pinning）。**Mac 同士**はカメラを使わず、同じ文字列（`sill:` + base64）を「Copy Code」→ もう一方の Settings のフィールドに貼る。中身も検証も QR と同一
3. iPhone が接続。iPhone 側 validator は Mac の fingerprint を検証。Mac 側 validator はペアリングモード中のみ未知の証明書を通し、その fingerprint を接続に紐づけて覚える
4. iPhone → `pair{token, deviceId, name}`。Mac は token を検証し、接続の fingerprint を `peer` に保存 → `paired{deviceId, name}`。token は使い捨て、ペアリングモード終了
5. 以後は通常の `hello`（9 節）。解除 = 両側で `peer` 行を削除

安全性: token は Mac の画面にしか出ず、iPhone は Mac の fingerprint を検証してから token を送るので、第三者は token を得られない。ペアリングモード中に無関係な端末が繋いでも token 不一致で切る。

不採用: A. TLS 1.2 PSK（旧 API 限定、forward secrecy 無し）。C. 平文 TCP + 自前暗号。

## 9. Sync Protocol（version vector + round）

方針: **change log を持たず、`note` 行そのものを「そのノートの最新 version」として扱う**。version = `(origin_device, origin_seq)`。各端末は `seen` ベクトル（端末ごとに見た最大 seq）を持つ。

これで台数が増えても同じプロトコルで済む: Mac を経由して iPhone の変更が iPad に届く（Mac は自分が書いた行だけでなく、相手が未見の行をすべて送る）。

- ローカル書き込み（編集・削除・競合解決）: `origin_device = me`, `origin_seq = seen[me] + 1`, `seen[me] = origin_seq`（カウンタはベクトルの自分の項そのもの）
- 送信対象: 相手のベクトル `V` に対し `origin_seq > V[origin_device]` の行すべて
- スナップショット = `{id, content, createdAt, updatedAt, deletedAt, originDevice, originSeq}`

メッセージ（`Coder` で JSON）: `hello{deviceId, name, protocolVersion:1, vector}` / `pair` / `paired` / `changes[≤100]` / `changesDone{vector}` / `poke` / `bye`。

接続直後に `hello` を交換し、以後は **round** を繰り返す。round は常に client（iPhone）が始める:

```
--- round ---
client → changes[…] → changesDone{clientVector}     -- server の vector に対して未見の行
server: 1 トランザクションで適用（10 節）+ seen = max(seen, clientVector)
server → changes[…] → changesDone{serverVector}     -- client の vector（適用後の最新値）に対して未見の行
client: 1 トランザクションで適用 + seen = max(seen, serverVector)
--- round end ---
```

round のトリガー: 接続直後 / client の autosave 後 1 秒 / server からの `poke`。round 中のトリガーは終了後にもう 1 round。

**中継**: Mac A が iPhone を serve しつつ Mac B を dial している構成では、片方の接続で入った変更をもう片方へ押し出す必要がある。`synced` イベントに `changed`（その round で実際に適用があったか）を載せ、true のときだけ反対側に `poke` / `localChanged` を出す（`MacSync.handle`）。空の round で poke し合うと無限に往復するので、この条件が要る。

順序の意味: client の変更が **先に適用される**ので、server が返す `serverVector` は client の全 version を含む。client 側では server の行が「自分の行の子孫」と判定され、通常は server だけが競合を解決する。

冪等性: 適用とベクトル更新は同一トランザクション。途中で切れても次 round で再送されるだけ。

**適用ルール**（受信 S、ローカル行 L、送信側ベクトル `SV`、自分のベクトル `MV`）:

| 状態 | 処理 |
|---|---|
| L 無し | insert（S の version のまま） |
| L.version == S.version | 何もしない |
| `SV` が L.version を含む（送信側は L を見た上で S を書いた） | S で上書き（S の version のまま） |
| `MV` が S.version を含む（自分は S を見た上で L を書いた） | L を維持 |
| どちらも含まない = 並行 | 競合（10 節） |

### 同期モデルの選択肢（比較・記録用）

同期の設計は独立した 3 軸に分かれる。★ が採用案。判断基準は「単一ユーザーのフローメモに必要な最小」。

**軸 1: 何を単位に、どう merge するか**

| 案 | 仕組み | 並行編集時 | コスト | 参考実装 |
|---|---|---|---|---|
| ★ A. ノート単位 LWW + version vector | 行 = 最新状態。ベクトルで因果関係を判定 | 新しい方が残り、古い方は複製ノート | 小。依存なし。Markdown 文字列が真実のまま | Syncthing がファイル単位で同じ方式（古い mtime を conflict copy、同時刻は device ID で決定、複製も通常ファイルとして伝播） |
| A'. A + diff3 自動 merge（v2 候補） | 「最後に同期した content」を base に 3-way merge | 非重複の編集は自動 merge、重複時だけ複製 | 中。diff3 実装 300〜500 行 + 列 1 つ | git、Obsidian Sync |
| B. ノート本文を text CRDT に | 文字単位の履歴を持ち、常に merge 可能 | 常に自動 merge、複製なし | 大。Rust コア + FFI 依存、保存形式が CRDT バイナリ、履歴が肥大、Markdown 文字列が真実でなくなる | Automerge（automerge-swift 0.7.2、2025-12）、Loro（loro-swift 1.13.3、2026-07）。yswift は 2024 で停止 |
| C. 操作ログ（event sourcing） | create / update / delete の追記ログを交換 | LWW か手動。A と同じ | 中。ログ圧縮が要る。A より得るものが無い | — |
| D. OT | サーバー中心の変換 | 自動 | 中央サーバー必須。local-first と矛盾 | Google Docs |

**軸 2: トポロジー / 経路**

| 案 | 評価 |
|---|---|
| ★ 直接 P2P のみ（近接時） | 仕様の要件そのもの。アカウント不要 |
| P2P + relay（将来） | 同じ round プロトコルを HTTPS で喋る受動的 peer。E2E 暗号化可能（15 節） |
| ファイル同期サービスに委譲（iCloud Drive / Dropbox） | 実装は最小だが、iCloud 排除の仕様に反し、競合処理を他社に委ねる |
| CloudKit / 中央サーバー | 仕様で除外 |

**軸 3: 保存形式**

| 案 | 評価 |
|---|---|
| ★ SQLite（GRDB） | 起動・保存・同期メタデータの扱いが最も単純。Copy as Markdown と将来の MCP / export で相互運用 |
| フォルダ内の .md ファイル + サイドカー DB | 「自分のデータは自分のファイル」という訴求は強い（Obsidian、iA Writer）。代わりに外部編集の検知、title 由来のファイル名と rename、iOS のファイル扱い、原子的書き込み、同期メタデータとファイルの突き合わせが必要。MVP の Speed と相反 |

OSS として見られる品質は、merge モデルの重さではなく次で担保する: `docs/sync-protocol.md`（メッセージ形式、状態機械、保証と非保証を明文化）、複数端末シミュレーションによる収束テスト、Sync engine を純関数に閉じ込めた読みやすい実装、ADR として残す判断記録。

## 10. Conflict 処理

並行 version 同士の解決。結果はすべて解決側の **新しい version**（origin = me）として書くので、相手にはベクトル判定で「子孫」として届き、収束する。

| ケース | 処理 |
|---|---|
| 両方 live、content が同じ | 書き込まず、`(origin_device, origin_seq)` が大きい方の version を採用（決定的） |
| 両方 live、content が違う | `updatedAt` が新しい方（同時なら origin_device の大きい方）を勝者とし、勝者 content を新 version として書く。敗者 content を **決定的 id** `uuid5(ns, noteId + loserOrigin + loserSeq)` の新ノートに書く。先頭行末尾に ` (Conflict from <端末名>)` を付け、それ以外は変えない |
| 片方 tombstone、片方 live | live が勝つ（復活）。content を新 version として書く。複製なし |
| 両方 tombstone | 大きい version を採用 |

**エディタで開いているノートに同期が来た場合**（`OpenNoteReconciliation`）: エディタが未編集なら新しい版を表示する。未保存の入力があるなら入力はそのまま続けさせ、届いた版の本文を「(Conflict from <端末名>)」付きの別ノートに退避してから、次の自動保存でローカルの本文を上書きする。端末の vector 上は「見た」ことになっていても、人が見ていない文章を黙って消さないための規則。実機テストでこの経路の消失を確認して追加した。

決定的 id の意味: 万一両側が同時に解決しても、複製ノートは同じ id・同じ content になり、二重にならない。

既知の制約: 「どちらが元の id に残るか」は端末の壁時計（`updatedAt`）で決めるので、時計が大きくずれた端末があると、実際には古い編集が元の id に残り、新しい方が複製側に回ることがある。文章はどちらも残るので損失はないが、表示上の「最新」が入れ替わる。中央サーバーの無い構成では避けにくく、MVP では受け入れる。

エディタからの保存（`NoteStore.saveEdit`）は「エディタが読み込んだ version」を期待値として 1 トランザクションで行う。その間に同期が別の版を入れていれば、その本文を複製ノートに退避してから保存する。エディタ側の観測が遅れても文章が消えない。

保証したい性質（テスト）: 任意の編集・削除・同期の列の後、全端末で round を一巡させれば、生存ノート集合（id と content）が全端末で一致し、どの端末で書かれた文章も消えていない。

## 11. Tombstone / 削除

- 削除 = `deleted_at = now`、`content = ''`、新 version。物理削除しない。一覧から除外。
- 空の新規ノートは DB に入らない設計なので掃除ルール不要。
- GC は MVP で作らない。

## 12. ノート切替 UI（案 1: 折りたたみサイドバー に決定）

検索は機能として持たない。比較した 2 案（記録用）:

| | 案 1: 折りたたみサイドバー（推奨） | 案 2: Raycast 型 Browse |
|---|---|---|
| 見た目 | 既定は 1 ノートだけの小窓。⌥⌘S でサイドバーが開き、`updatedAt` 順の一覧（title 行 + 相対時刻）が左に出る | 常に 1 ノート。⌘P で一覧ポップアップが重なり、選ぶと閉じる |
| 操作 | ↑↓ で選択、Return でエディタへ、⌥⌘S で閉じる。開閉状態は記憶 | ↑↓ Return。閉じたら消える |
| 向く場面 | 一覧を眺めながら行き来する | 目的のノートが決まっている |

iOS は Apple メモ型（一覧 → エディタ）。起動時は最後のノートを直接開き、戻るで一覧。一覧は Apple メモと同じく Today / Yesterday / Previous 7 Days / Previous 30 Days / 月 / 年でセクション分けし（UI 文言は英語で統一、ロケールに依存しない）、行は太字タイトル + 更新日付 + 本文プレビュー（`NoteListGrouping`、純関数）。

## 13. Project / Module 構成

```
sill/
  project.yml
  Packages/SillCore/
    Package.swift                  # deps: GRDB.swift, swift-certificates(X509)
    Sources/SillCore/
      Model/      Note.swift, NoteTitle.swift
      Store/      Database.swift (migrations), NoteStore.swift
      Sync/       SyncMessage.swift, SyncEngine.swift (純関数), SyncSession.swift (round 進行)
      Identity/   DeviceIdentity.swift (cert 生成 + Keychain), Fingerprint.swift
      Transport/  SillListener.swift, SillBrowser.swift, SillConnection.swift
      Editing/    MarkdownEditing.swift
    Tests/SillCoreTests/           # store / sync 収束（複数端末シミュレーション）/ editing / identity
  Apps/Mac/     SillApp.swift, AppDelegate.swift, FloatingPanel.swift, EditorTextView.swift,
                SidebarView.swift, PairingQRView.swift, Info.plist, Sill.entitlements
  Apps/iOS/     SillApp.swift, NoteListView.swift, EditorView.swift, ScanPairingView.swift, Info.plist
  docs/design.md
  Makefile                         # gen / build / test / run
```

- 外部依存: GRDB.swift、swift-certificates（+ swift-crypto、swift-asn1）、KeyboardShortcuts（macOS のみ）。
- macOS は App Sandbox ON（`network.client` + `network.server`）。Keychain は data protection keychain。
- 将来の MCP: `SillCore` + 同じ SQLite ファイルを読む別プロセスで足りる。

## 14. MVP 実装順序

| # | スライス | 完了条件 | 状態 |
|---|---|---|---|
| 0 | Xcode 最新版、XcodeGen、空の 2 target がビルド | `make build` | 済 |
| 1 | SillCore: schema + NoteStore + tests | `swift test` で create / update / delete / tombstone | 済 |
| 2 | Identity: 証明書生成 + Keychain + SecIdentity 取得 | 両 OS で identity が作れ、再起動後も同じ fingerprint | 済（Mac は team 署名 + keychain-access-groups が必要） |
| 3 | **Transport spike**: Bonjour + 相互 TLS + Coder で Mac ↔ iPhone に `hello` 往復、接続維持と `poke` | 実機で往復成功。最大リスクを最初に潰す | 済（実機で Bonjour 発見 → 相互 TLS → round → poke まで確認） |
| 4 | Mac capture: Dock app + hotkey + NSPanel + editor + autosave + Esc | Scenario A。表示レイテンシ計測 | 済（再表示は os_signpost で計測し、テストで 100ms 未満を保証） |
| 5 | 編集ヘルパー + Copy as Markdown (⌘⇧C) + ⌘N + 最終ノート復帰 | Scenario B | 済 |
| 6 | サイドバー + 削除 | キーボードだけで切替完結 | 済 |
| 7 | iOS: 一覧・エディタ・autosave | Scenario C | 済 |
| 8 | Sync engine（純関数）+ 収束テスト（3 端末シミュレーション、ランダム操作） | 生存集合一致・文章消失なしが緑 | 済（16 seed × 400 操作） |
| 9 | Transport と engine を結合、QR ペアリング | Scenario D / E を実機で通す | 済。`make device-check DEVICE=<id>` で実機の双方向同期を自動検証 |
| 10 | pin、同期状態表示、hotkey recorder、unpair | 仕上げ | 済（pin は ⌘⇧P、hotkey は Settings で変更） |
| 11 | Mac ↔ Mac 同期（`MacDialer` + `SyncRole` + コード貼り付けペアリング） | 2 台の Mac が 1 本の接続で双方向に同期し、片方に繋いだ iPhone にも中継で届く | 済（`Tests/Mac/MacToMacSyncTests.swift` で id の順序を両方通す。実機確認は 15 節） |

テスト方針: SillCore は `swift test`（同期セッションはメモリ内チャネルで、識別は swift-certificates の証明書で検証）。実機は `scripts/device-sync-check.sh`: Mac を `SILL_DEBUG=1` で起動して `sill://debug/...` で操作し、iPhone は `devicectl` の環境変数でノートを作らせ、両 DB（iPhone 側は `devicectl device copy from` で取得）で到達を確認する。両アプリは `Application Support/Sill/sync.log` に同期の経過を残す。ホスト型テストでは 127.0.0.1 上で本物の相互 TLS（pinning）を張り、アプリの listener / client と結合した端末間フローまで通す。Mac の UI 挙動は Sill.app 内で動くホスト型テスト（`Tests/Mac`）で、NSTextView に実際のキーイベントを流して検証する。iOS も同様に simulator 上の Sill.app 内で動くホスト型テスト（`Tests/iOS`）で、UITextView の `insertText` 経路（実キーボードと同じ）を通す。`SILL_TEST_MODE=1` で使い捨て DB を使い、Mac ではパネルが key にならず accessory ポリシーで起動する（他アプリへの入力を奪わない）。XcodeGen の sources は `syncedFolder` にしてあり、ファイル追加で再生成は不要。

## 15. 次にやること（2026-09-05 時点の引き継ぎ）

決定待ち（オーナー）:
- **公開の切り替え**（private → public）。public にしたら branch protection を API で入れる（force push 禁止、linear history、admin にも適用）。
- **Release の Secrets**（Developer ID 証明書 p12、App Store Connect API キー、Team ID）。入れたら `v0.1.0` タグで初回リリースを試し、公証まで通す。
- **LICENSE の名義**（現状 MIT / mrskiro）。
- **README の言語**（現状日本語。英語版にするか）。

実装:
- **iOS の書式ツールバー**（最後に回す指示あり）: 純正メモのようにキーボード上部に「箇条書き / 番号付き / チェックボックス / 太字 / 斜体 / コード / 見出し / インデント」を並べ、Markdown 記法を挿入・トグルする。本文は Markdown 文字列のまま。`MarkdownEditing` に純関数として追加し、Mac のメニューからも同じ関数を呼ぶ。
- iOS の実機で `PhoneSync` の再接続ループとローカルネットワーク許可の挙動を長時間（数日）観察する。Scenario E の実運用確認。
- Sync 状態の UI（Mac ヘッダー / iOS 下部バー）の文言と更新頻度の見直し。
- `PhoneSync` と `MacDialer` の dial ループ（browse → connect → バックオフ）はほぼ同じ。3 つ目が要るときに `SillCore` へ寄せる。今は片方が foreground 依存、もう片方が `SyncRole` 依存で、共通化しても得が小さい。
- 2 台の Mac での実運用確認: 実機同士で Bonjour 発見、初回の Local Network 許可（Mac が browse するのは今回が初めて）、スリープ復帰後の再接続。

## 16. 将来の拡張方向（設計上の制約として意識するもの。MVP では作らない）

- **端末追加（iPad）**: `peer` 行を増やすだけ。version vector なので Mac をハブに推移的に届く。iPhone ↔ iPad 直結は両方 foreground が要り、対称ロールと dedup が必要になるので後回し（2 台目の Mac は 7 節の `SyncRole` で実装済み）。
- **離れた場所での同期（relay）**: 同じ round プロトコルを HTTPS 上で喋る「受動的な peer」（例: Cloudflare Durable Object）。ペアリング QR に vault 鍵を 1 つ足せば relay は暗号化された行とベクトルしか持たない E2E 構成にできる。アカウントは不要のまま。
- **安全な自動 merge**: 各ノートに「最後に同期した content」を持てば diff3 で非重複編集を自動 merge できる。今の行構造に列を 1 つ足すだけ。
- **MCP**: `list_notes / read_note / search_notes` は SQLite 読み取りで足りる。

## 決定事項

| # | 項目 | 決定 |
|---|---|---|
| 1 | Xcode | 26.6 以上（iOS 26 SDK と新 Network API のため） |
| 2 | ペアリング | B: 自己署名証明書 + fingerprint pinning、新 Network API、相互 TLS |
| 3 | Mac の形態 | Dock アプリ + hotkey。メニューバーアイコン無し |
| 4 | hotkey | ⌥S。Settings（⌘,）で変更可 |
| 5 | 検索 | 持たない |
| 6 | 切替 UI | 折りたたみサイドバー（⌥⌘S） |
| 7 | merge モデル | A: ノート単位 LWW + version vector + 複製ノート。diff3 は必要になったら v2 |
| 8 | 保存形式 | SQLite（GRDB）。export / MCP は後から |
| 9 | 同期の起点 | iPhone が接続を維持し、Mac は `poke` で round を起こす |
| 10 | Mac 同士 | 両方が listener 兼 client。device id の小さい方が dial する（`SyncRole`）。ペアリングはコードを貼る側が 1 回だけ dial |
