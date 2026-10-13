# macDisplayCtl

<div align="center">

**ネイティブパネルやコマンドラインから macOS のディスプレイモードを切り替え。**

[English](README.md) | [简体中文](README_CN.md) | 日本語

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white)

</div>

macDisplayCtl は、SwiftUI/AppKit 製のネイティブアプリ **macDisplayCtl.app** とコマンドラインツール `macDisplayCtl` を備えた macOS 用ディスプレイ管理ツールです。4 つの投影モード、ディスプレイごとの有効化・無効化、および外部ディスプレイの切断時に内蔵ディスプレイを復帰させるバックグラウンド監視機能を提供します。アプリの初回起動時に自動的に有効になります。

## 主な機能

- 内蔵のみ、ミラーリング、拡張、外部のみの 4 モードを切り替え。
- 拡張モードに戻ると、以前の画面配置とメインディスプレイを復元。
- 2 台目として使用する物理的な外部ディスプレイを選択。
- メニューバーや **Control + Option + P** から半透明パネルを表示。
- コマンドラインから種類や ID を指定してディスプレイを有効化・無効化・切り替え。
- `--dry-run` による操作のプレビューと、スクリプト向けの JSON 一覧出力。
- 最後の有効な非仮想ディスプレイを誤って無効化しないための保護。
- 外部ディスプレイ切断時に内蔵ディスプレイを一時復帰し、再接続後に以前の状態へ戻す機能。
- 初回起動時に自動復帰とログイン時起動を有効化し、アプリとは独立して動作する監視プロセス。

アプリ、コマンドライン、監視メッセージはシステム言語に従います。中国語の場合は簡体字中国語、それ以外は英語です。英語のアプリ名は「macDisplayCtl」、中国語では「屏幕切换」です。ドキュメントは英語、簡体字中国語、日本語で提供しています。

## 動作要件

- macOS 13 Ventura 以降。ディスプレイ制御は非公開システム API に依存するため、対応状況は macOS のバージョンとハードウェアによって異なります。
- ソースからのビルドには Xcode、または Clang と Swift を含む Xcode Command Line Tools。
- バックグラウンド監視のインストール、更新、起動および検証の実行には `python3` として実行できる Python 3。

ビルド済みアプリにはコンパイル済みのコマンドラインヘルパーが含まれ、ソースディレクトリなしで実行できます。ビルドスクリプトは ad-hoc 署名を使用し、Developer ID による公証は行いません。

## ソースからビルド

```sh
git clone https://github.com/kevin808/macDisplayCtl.git
cd macDisplayCtl
./build-app.sh
open "build/macDisplayCtl.app"
```

アプリは `build/macDisplayCtl.app` に生成され、`/Applications` にコピーできます。macOS が起動をブロックする場合は、**システム設定 > プライバシーとセキュリティ**で起動を許可してください。

コマンドラインの `./macDisplayCtl` ランチャーは初回実行時にヘルパーをコンパイルし、`macDisplayCtl.m` の更新後に再ビルドします。[`macDisplayCtl.command`](macDisplayCtl.command) をダブルクリックすると、システム言語に従う対話メニューも使用できます。

## アプリの使い方

アプリはデフォルトで Dock にアイコンを表示しません。メニューバーのアイコンを右クリック（または Control を押しながらクリック）すると、終了を選択できます。メニューバーのディスプレイアイコンをクリックするか、**Control + Option + P** を押すとパネルを表示・収納できます。パネル表示中は `1`、`2`、`3`、`4` でモードを選択します。

| キー | アプリ内の表示 | 動作 |
| --- | --- | --- |
| `1` | Built-in Only（内蔵のみ） | 内蔵ディスプレイを有効化し、ミラーリングを解除して物理的な外部ディスプレイを無効化します。 |
| `2` | Mirror（ミラーリング） | 内蔵と選択した外部ディスプレイを有効化し、内蔵画面を外部に複製します。 |
| `3` | Extend（拡張） | 両方を有効化し、ミラーリングを解除して以前の拡張時の配置を復元します。 |
| `4` | External Only（外部のみ） | 選択した外部ディスプレイを有効化して確認した後、ミラーリングを解除して内蔵ディスプレイを無効化します。 |

外部ディスプレイが接続されていない場合、Mirror、Extend、External Only は無効になり、カーソルを合わせると接続を促す説明が表示されます。接続されたままアプリで無効化した画面は再度有効にできます。接続状態の変更でパネルを自動更新し、切り替え前にも再確認します。切り替え中に切断された場合はエラーダイアログを表示せず状態を更新し、一時的な構成拒否には再試行の案内を表示します。接続を確認できない場合は、接続済み画面を誤って無効にしないよう選択肢を維持します。

物理的な外部ディスプレイの候補が複数ある場合のみ、ヘッダーに選択欄が表示されます。1 台の場合は自動的に選択されます。投影モードは内蔵と選択した外部ディスプレイを使用し、それ以外の有効な物理外部ディスプレイを無効化します。仮想ディスプレイは対象外です。キャッシュに残った未接続のディスプレイには **Disconnected**（未接続）と表示されます。有効化に失敗した場合は、現在使用できるディスプレイを維持します。ミラーリング時の解像度は macOS とディスプレイによって決まります。

モード切り替え前に、物理ディスプレイの組み合わせごとに拡張時の位置とメインディスプレイを保存します。拡張に戻ると、上下配置や位置のずれも復元します。macOS のディスプレイ設定で変更した配置は、次の切り替え時に記録します。UUID が取得できる場合はアプリやシステムの再起動後も同じディスプレイを識別します。UUID がない場合、数値 ID は今回の起動中のみ使用します。記録がなければ macOS が提供する有効な配置を維持し、それもなければ外部画面を右側に配置します。この機能の導入前に失われた配置は、macOS のディスプレイ設定で一度設定し直してください。

デスクトップの空白部分や別のアプリをクリックすると、パネルが自動的に閉じます。右上の大きな閉じるボタンや **Esc** でも閉じられます。メニューバーのアイコンまたは **Control + Option + P** で再表示でき、**Command + Q** でアプリを終了します。パネルには 4 つの投影モードがあり、操作に失敗するとダイアログを表示します。パネル、アプリ、対話メニューを閉じても、独立した監視プロセスは停止しません。

アプリの初回起動時に、外部ディスプレイ切断後の内蔵ディスプレイ自動復帰とログイン時起動を有効にします。その後、動作中の監視ヘルパーが同梱版と異なる場合は更新します。初期設定後に `guard stop` で明示的に停止した監視は停止状態を維持します。再開には `guard start` を使います。

## 言語設定

アプリは macOS の優先言語に従います。**システム設定 > 一般 > 言語と地域 > アプリケーション**でアプリごとの言語も指定できます。変更後はアプリを再起動してください。アプリのファイル名は `macDisplayCtl.app` で、Finder はローカライズされた表示名を使用します。

単独のコマンドラインツールと対話メニューもシステム言語に従います。コマンドごとに指定する場合は `MACDISPLAYCTL_LANGUAGE` を使用します。

```sh
MACDISPLAYCTL_LANGUAGE=en ./macDisplayCtl --help
MACDISPLAYCTL_LANGUAGE=zh-Hans ./macDisplayCtl --help
```

## コマンドライン

リポジトリのディレクトリで実行してください。数値 ID は例です。再起動や再接続で変わることがあるため、`list` で確認した ID に置き換えてください。

```sh
./macDisplayCtl list                         # ディスプレイと ID を表示
./macDisplayCtl list --json                  # JSON 出力
./macDisplayCtl off builtin                  # 内蔵を無効化
./macDisplayCtl on builtin                   # 内蔵を有効化
./macDisplayCtl off external                 # すべての外部を無効化
./macDisplayCtl on external                  # すべての外部を有効化
./macDisplayCtl toggle 2                     # ID 2 を切り替え
./macDisplayCtl on all                       # 認識済みのすべてを有効化
./macDisplayCtl off builtin --dry-run        # 変更せずにプレビュー
./macDisplayCtl project internal             # 内蔵のみ
./macDisplayCtl project duplicate 3          # 外部 ID 3 にミラーリング
./macDisplayCtl project extend 3             # 外部 ID 3 に拡張
./macDisplayCtl project external 3           # 外部 ID 3 のみ
./macDisplayCtl project extend --dry-run     # 投影計画をプレビュー
./macDisplayCtl --help
```

既定では、最後の有効な非仮想ディスプレイの無効化を拒否します。同じ操作で有効化を予定しているディスプレイは、現在利用可能な代替画面としては扱いません。すべてを無効化するには `./macDisplayCtl off all --allow-all-off` を明示的に使用します。無効な状態を維持する場合は、先に復帰監視を停止してください。監視中は、ふたが開いていると内蔵ディスプレイが復帰する場合があります。

終了コード：`0` は成功・変更不要・プレビュー成功、`1` は API またはトランザクションの失敗、`2` は引数の誤りまたは保護による拒否、`3` は変更を確定したものの 2 秒以内に期待する状態を確認できなかったことを示します。

## 自動復帰と状態記憶

```sh
./macDisplayCtl guard status                 # 監視の状態を確認
./macDisplayCtl guard start                  # インストール/更新・起動・ログイン時起動を有効化
./macDisplayCtl guard stop                   # 停止し、ログイン時起動を無効化
./macDisplayCtl watch --dry-run --once        # 画面・ふた・復帰判断を読み取りのみで確認
```

最後の使用可能な非仮想ディスプレイがなくなり、内蔵も無効な場合、その状態が 1 秒以上続くのを待って内蔵ディスプレイを一時的に有効化します。復帰にはふたが開いている必要があり、閉じている場合や状態が不明な場合は待機します。

物理的な外部ディスプレイが再接続され、2 秒以上安定すると、切断前の内蔵ディスプレイの状態に戻します。内蔵を無効化する直前に、使用可能な物理外部ディスプレイがあることを再確認します。監視は外部ディスプレイを無効化しません。

初期設定は外部ディスプレイ接続中の内蔵の状態から学習し、その後は外部接続中かつふたが開いているときの選択を記憶します。一時的な復帰で設定を上書きすることはありません。再接続後も内蔵を有効にするには、切断中に `./macDisplayCtl on builtin` を明示的に実行してください。すでに有効な場合も適用されます。切断中に他のアプリで状態を変更した場合は、ユーザーの選択とシステムによる自動復帰を確実には区別できません。

監視はディスプレイ構成とふたのイベントを監視し、5 秒ごとにも確認します。一時復帰の再試行間隔は 10 秒以上で、3 回試すごとに 60 秒待機します。再接続時の状態復元も 10 秒以上の間隔で再試行します。長いスリープの後は改めて安定を待ちます。画面切り替えと監視は共通の操作ロックを使用します。

`sudo` やシステム全体の起動項目は不要です。ソース更新後は `./macDisplayCtl guard start` でインストール済み監視を更新します。インストール時には以前の実行ファイルと起動設定の `.backup` を保存します。

## ローカルデータとログ

以下は現在のユーザーのホームディレクトリを基準とするパスです。

| パス | 用途 |
| --- | --- |
| `~/Library/Application Support/macDisplayCtl/macDisplayCtl` | インストール済み監視プログラム |
| `~/Library/Application Support/macDisplayCtl/displays.json` | ディスプレイ識別情報のキャッシュ |
| `~/Library/Application Support/macDisplayCtl/guard-state.json` | 内蔵の設定と復元待ち状態 |
| `~/Library/Application Support/macDisplayCtl/builtin-intent.json` | 本ツールで明示した内蔵の選択 |
| `~/Library/Application Support/macDisplayCtl/extended-layouts.json` | 拡張時の画面配置とメインディスプレイ |
| `~/Library/LaunchAgents/local.macDisplayCtl.guard.plist` | ユーザー用 LaunchAgent |
| `~/Library/Logs/macDisplayCtl-guard.log` | 監視ログ |

実行ファイル、データディレクトリ、ログ、LaunchAgent は `macDisplayCtl` に統一し、macOS のバックグラウンド活動でアプリに関連付けます。旧版の `displayctl` データは取り込みません。

キャッシュと記憶した設定は現在のシステム起動中に有効です。監視の再起動・更新後も設定を引き継ぎ、システム再起動後は再学習します。取得できる場合は UUID を使い、数値 ID が変わっても同じディスプレイを識別します。

キャッシュに残ったディスプレイはケーブルが抜かれている可能性があります。`on all` はすべてのハードウェアの再検出を保証しません。有効化に失敗する場合は、`list` で有効な ID を確認し、個別に指定してください。

## 開発と検証

```sh
./build-app.sh
./test.sh
```

テストスクリプトはシミュレーションでコマンド計画、復帰ルール、再接続時の記憶、投影計画を検証し、実機の画面は切り替えません。ビルド済みアプリがある場合は GUI 状態のデコードを検証し、アプリ署名も確認します。Shell 構文と Git diff の空白も確認します。これらの検証はすべてのディスプレイや Mac との互換性を保証するものではありません。

| ファイル | 用途 |
| --- | --- |
| [`macDisplayCtl.m`](macDisplayCtl.m) | Objective-C による画面制御・監視・計画テスト |
| [`macDisplayCtl`](macDisplayCtl) | 自動コンパイル用ランチャー |
| [`macDisplayCtl-guard`](macDisplayCtl-guard) | ユーザー用 LaunchAgent の管理 |
| [`App/macDisplayCtl.swift`](App/macDisplayCtl.swift) | SwiftUI/AppKit パネル |
| [`App/Localization.swift`](App/Localization.swift)、[`App/Resources`](App/Resources) | 言語の選択とローカライズ用リソース |
| [`tests/localization.py`](tests/localization.py) | 翻訳と CLI 言語の回帰検証 |
| [`App/MakeIcon.swift`](App/MakeIcon.swift) | アプリアイコンの生成 |
| [`App/Info.plist`](App/Info.plist) | アプリ情報 |
| [`build-app.sh`](build-app.sh) | アプリのビルドと ad-hoc 署名 |
| [`test.sh`](test.sh) | 検証スクリプト |

## 制限事項

- 有効化・無効化は macOS の画面配置からディスプレイを復元・除外する操作です。DDC によるハードウェア電源の制御ではありません。
- 非公開 API `CGSConfigureDisplayEnabled` を使用します。Intel Mac、一部の M3 内蔵ディスプレイ、仮想・サードパーティーの表示環境では正常に無効化・再接続できない場合があります。
- 投影モードには内蔵ディスプレイが必要です。仮想ディスプレイの判定は macOS が返すフラグに依存します。
- 変更は現在のログインセッションに適用し、永続的な表示設定には書き込みません。トランザクションの戻り値を確認し、確定後は最大 2 秒間状態を確認します。構成に失敗したトランザクションは取り消します。
- 他のディスプレイ管理ソフトが変更を上書きする場合があります。監視は待機ルールに従って再試行します。

問題を報告する際は、macOS のバージョン、Mac の機種、ディスプレイの接続方式、使用したコマンドまたは投影モード、関連ログを添えてください。
