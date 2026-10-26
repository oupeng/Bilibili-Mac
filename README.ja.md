<p align="center">
  <img
    src="Design/AppIcon/v1/Marketing/BiliKit-AppIcon-Default-256.png"
    width="136"
    height="136"
    alt="BiliKit App Icon Default"
  >
  &nbsp;&nbsp;
  <img
    src="Design/AppIcon/v1/Marketing/BiliKit-AppIcon-Dark-256.png"
    width="136"
    height="136"
    alt="BiliKit App Icon Dark"
  >
</p>

<h1 align="center">BiliKit</h1>

<p align="center"><strong>Mac で、bilibili をもっと快適に。</strong></p>

<p align="center">Mac ネイティブ技術で作られた、非公式のオープンソース bilibili クライアント</p>

<p align="center">
  <img alt="macOS 15 以降" src="https://img.shields.io/badge/macOS-15%2B-195CFF?style=flat">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-195CFF?style=flat">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-FF607A?style=flat">
  <a href="https://github.com/shiinayane/BiliKit-Mac/releases/latest"><img alt="最新バージョン" src="https://img.shields.io/github/v/release/shiinayane/BiliKit-Mac?label=%E3%83%90%E3%83%BC%E3%82%B8%E3%83%A7%E3%83%B3&color=FF607A&style=flat"></a>
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/ライセンス-MIT-4A5568?style=flat"></a>
</p>

<p align="center">
  <a href="https://github.com/shiinayane/BiliKit-Mac/releases/latest"><strong>BiliKit をダウンロード</strong></a>
</p>

<p align="center">
  <a href="README.md">简体中文</a> · <a href="README.en.md">English</a> · <strong>日本語</strong>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Design/Marketing/v2/BiliKit-Home-Dark.png">
    <img src="Design/Marketing/v2/BiliKit-Home-Light.png" alt="BiliKit のホーム：サイドバーにライブラリとお気に入り、右側におすすめ動画のグリッド">
  </picture>
</p>

## BiliKit を選ぶ理由

|  | Web 版 / 公式 Mac クライアント | BiliKit |
| --- | --- | --- |
| 技術スタック | 公式クライアントは Electron 製で、実質的には Web ページ | UI は SwiftUI、動画グリッド・コメント・弾幕など性能が重要な部分は AppKit、再生は AVPlayer |
| インストーラ | 公式クライアントは 200 MB 近く | 10 MB 未満 |
| メモリ使用量 | 公式クライアントはしばしば 1 GB 超 | 100 MB 前後 |
| おすすめ | 広告、ライブ配信、各種ポップアップが混ざる | 動画だけ。プロモーションカードや動画以外の項目は除外 |
| 動画を見終えたら | タブが増え続け、元の一覧に戻れない | 同じウインドウで戻れて、一覧は元の位置のまま |
| プレーヤー | Web プレーヤー | システムのプレーヤー：ピクチャ・イン・ピクチャ、フルスクリーン、メディアキー、コントロールセンター |
| ログインしないとき | 画質に制限あり | 720P と 1080P を選べる |

<sub>公式クライアントの技術スタックとインストーラのサイズは、公式ダウンロード（`pc_electron_mac/bili_mac.dmg`、2026 年 9 月）に基づきます。</sub>

## できること

- **ブラウズ**：ホームのおすすめ、人気、検索。それぞれスクロール位置を覚えています。検索画面にはこの Mac の検索履歴と bilibili 急上昇ワードがあり、入力中は候補が出ます。
- **ライブラリ**（ログイン時）：サイドバーの「ライブラリ」に「あとで見る」と視聴履歴、「お気に入り」に自分で作ったお気に入りフォルダが並びます。視聴履歴にはどの種類のデバイスで見たかを表示。「あとで見る」は追加日順の並べ替え、進捗・追加日・長さでの絞り込みと検索ができます。お気に入りフォルダを開くと中の動画をページ単位で表示し、並べ替えとフォルダ内検索ができます。アニメ、講座、コレクション、音声、無効になった項目は理由を表示し、開けません。
- **カードメニュー**：動画カードを右クリックすると、リンクのコピーやブラウザで開くことができます。ログイン時は「あとで見る」への追加もでき、「あとで見る」画面では右クリックか ⌘⌫ で削除できます。
- **再生**：自動画質、再生速度、ピクチャ・イン・ピクチャ、フルスクリーン、システムの字幕・オーディオトラックメニュー、再生中の情報（Now Playing）とメディアキー。
- **弾幕**：映像と同じタイムラインで動くので、シーク、一時停止、速度変更でもずれません。プログレスバーをドラッグしたあとも、弾幕は本来の位置にすぐ表示されます。速度、表示エリア、密度、透明度を調整でき、大会員のカラー弾幕もそのまま表示します。
- **動画ページ**：エピソード、概要、閲覧専用のコメント（返信、画像、アニメーション画像）、関連動画がプレーヤーの横にまとまっています。概要やコメント内の動画リンク、@ メンション、タイムスタンプはアプリ内で開いたりジャンプしたりできます。ログイン時は投稿者をクリックすると、サイドバーでその投稿を続けて視聴でき、再生中の動画は止まりません。
- **ログイン**：bilibili アプリで QR コードを読み取ってログイン。視聴の進捗は bilibili の視聴履歴に同期されます。
- **アップデート**：インストーラは Apple による署名と公証済みで、新しいバージョンはアプリ内で通知されます。
- **表示言語**：簡体字中国語、繁体字中国語、英語、日本語。システムの言語設定に従います。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Design/Marketing/v2/BiliKit-Video-Detail-Dark.png">
    <img src="Design/Marketing/v2/BiliKit-Video-Detail-Light.png" alt="BiliKit の動画ページ：プレーヤー上の弾幕と字幕、サイドバーの概要とコメント、下に関連動画">
  </picture>
</p>

## キーボードショートカット

| キー | 動作 |
| --- | --- |
| スペース | 再生 / 一時停止 |
| ← / → | 5 秒戻る / 進む |
| ← / → を長押し | 一時的に 0.5 倍 / 2 倍速、離すと元に戻る |
| ↑ / ↓ | 音量 |
| D | 弾幕のオン / オフ |
| C | 字幕のオン / オフ |
| F | フルスクリーンの開始 / 終了 |

## 今後の予定

現在予定している項目はありません。

詳しくは[ロードマップ](docs/ROADMAP.md)（中国語）をご覧ください。

## インストール

1. [最新版の DMG](https://github.com/shiinayane/BiliKit-Mac/releases/latest) をダウンロードします。
2. BiliKit を「アプリケーション」にドラッグして開きます。

Apple シリコン搭載の Mac（M シリーズチップ）と macOS 15 以降が必要です。Intel Mac では、Intel に対応した最後のバージョンである
[1.0.0](https://github.com/shiinayane/BiliKit-Mac/releases/tag/v1.0.0) をお使いください。
インストール、アンインストール、アップデートの詳細は[配布に関する説明](DISTRIBUTION.md)（中国語）をご覧ください。

## よくある質問

<details>
<summary>公式クライアントですか？</summary>

いいえ。BiliKit は非公式のオープンソースプロジェクトで、bilibili との提携、承認、後援の関係はありません。
</details>

<details>
<summary>ログインしても安全ですか？</summary>

ログインには bilibili 公式の QR コードを使います。ログイン情報はこの Mac のキーチェーンにだけ保存され、iCloud には同期されません。
アップデート確認用のフィードを除き、BiliKit は独自のサーバを持たず、解析や広告の SDK も含みません。あなたの代わりに「いいね」、コイン投げ、フォローをすることもありません。詳しくは[プライバシーに関する説明](PRIVACY.md)（中国語）をご覧ください。
</details>

<details>
<summary>ダウンロード、ライブ配信、複数アカウントに対応する予定は？</summary>

ありません。どれも計画にはなく、BiliKit は動画を見ることだけを丁寧に作り込みたいと考えています。
</details>

<details>
<summary>ソースからビルドする</summary>

Xcode で `BiliKitMac.xcodeproj` を開き、`BiliKitMac` スキームと「My Mac」を選んで実行します。すべてのチェック：

```sh
sh Scripts/run-quality-gates.sh app
```

以下のドキュメントは中国語です：
[アーキテクチャ](docs/ARCHITECTURE.md) · [セキュリティモデル](docs/SECURITY-MODEL.md) · [リリース手順](docs/release/README.md) ·
[セキュリティ問題の報告](SECURITY.md) · [App Icon のソース](Design/AppIcon/v1/) · [スクリーンショット](Design/Marketing/v2/)
</details>

## ライセンスと表記

ソースコードは [MIT License](LICENSE) で提供しています。BiliKit の名称、アイコン、宣伝素材は MIT License の対象外です。
[ブランド資産に関する権利表記](BRAND-ASSETS.md)（中国語）をご覧ください。サードパーティの依存関係は [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)（中国語）に記載しています。
bilibili に関連する名称と商標は、それぞれの権利者に帰属します。
