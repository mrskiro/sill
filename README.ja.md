# Sill

[![CI](https://github.com/mrskiro/sill/actions/workflows/ci.yml/badge.svg)](https://github.com/mrskiro/sill/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/mrskiro/sill?label=release)](https://github.com/mrskiro/sill/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

思いついたものを、窓辺に一旦置くように書ける、小さなローカルファースト Markdown メモ。
アカウントもサーバーも無く、端末同士が近くにいるときだけ直接同期します。

[サイト](https://mrskiro.github.io/sill/) · [English](README.md)

## インストール

**Mac** — [最新リリース](https://github.com/mrskiro/sill/releases/latest)の dmg を
落として、Sill を Applications にドラッグしてください。署名・公証済みなので macOS が
起動を拒否することはありません（初回だけ「インターネットからダウンロードされた
アプリです」の確認が出ます）。macOS 26 以降が必要です。

**iPhone** — まだ App Store には出していません。ソースからビルドして、Mac の
Settings からペアリングしてください。

## できること

- **⌥S** で、作業中の画面の上にパネルが出ます。**Esc** で消えます。
- ノートは端末内の SQLite ファイル 1 つに入ります。ネットワークを待つ処理はありません。
- 入れた Markdown がそのまま残ります。スマートクォートも自動大文字化もしません。
- 一度ペアリングすれば、あとは同じローカルネットワークで見つかったときに相互 TLS で
  同期します。Mac 同士も同期します。
- メニューバーアイコンも常駐の更新チェックもありません。更新は押したときだけ見ます。

Mac のキー: **⌥S** 表示/非表示（Settings で変更可）、**Esc** 閉じる、**⌘N** 新規、
**⌘⇧C** Markdown としてコピー、**⌥⌘S** サイドバー、**⌘⌫** 削除、**⌘⇧P** ピン、
**Return / Tab / ⇧Tab / ⌘Return** でリスト操作。

ペアリングは Mac の Settings（⌘,）→ **Pair a Device…** から。iPhone とは Sync 画面で
QR コードを読み取り、Mac 同士は **Copy Code** で写して相手の Settings に貼ります。

## ビルド

```sh
xcode-select -p        # Xcode 26.6 以上を指していること
brew install xcodegen  # 一度だけ

make gen               # project.yml → Sill.xcodeproj（生成物。gitignore 済み）
                       # 同時に Configs/Local.xcconfig を example から作る
$EDITOR Configs/Local.xcconfig   # 自分の DEVELOPMENT_TEAM を入れる。入れないと署名で失敗する
make build             # macOS + iOS simulator
make test              # SillCore の単体テスト + 両アプリのホスト型テスト
```

`Configs/Local.xcconfig` は gitignore 済みです。Mac アプリはローカルビルドでも team
署名になります（端末 identity を data protection keychain に置くため）。

## 開発に参加する

Issue も Pull Request も歓迎します。手順と規約は [CONTRIBUTING.md](CONTRIBUTING.md)、
脆弱性の報告は [SECURITY.md](SECURITY.md) にあります。設計と判断の経緯は
[docs/design.md](docs/design.md) です。

## ライセンス

MIT © 2026 mrskiro
