# Microsoft Store への提出の手順と記載内容

ぴたトラック（Store 版、MSIX）を Partner Center から Microsoft Store に出すための手順と、各欄に書く内容の案です。

- 最初は「非公開の対象ユーザー」で出し、スマート アプリ コントロール（SAC）がオンの仮想マシンで Store から入れて確かめます（`dev\sac-test`）。問題がなければ、一般公開に切り替えます。
- 欄の名前は Partner Center の画面に合わせて、日本語と英語を併記しています。画面の表記が少し違うことがあります。
- 文案は案です。実際の画面に合わせて直してください。

## 1. 事前準備（1 回だけ）

1. Partner Center（https://partner.microsoft.com/dashboard）で「新しい製品」を作り、アプリの名前「ぴたトラック」を予約します（2026-10-19 に予約済み）。
   - 英語の名前「PitaTrack」も使うときは、製品を増やさず、同じ製品の「製品の管理 → アプリ名の管理（Manage app names）」の「その他の名前を予約（Reserve more names）」で予約します。1 つの製品に名前を複数予約でき、言語ごとの掲載情報で使う名前を選べます。
   - インストールしたあとの表示名は、パッケージのマニフェストの名前（今は「ぴたトラック」だけ）です。英語の Windows で「PitaTrack」と出したいときは、マニフェストに英語の表示名を足す変更が別に要ります。
2. 「製品の管理 → 製品 ID（Product identity）」の 3 つの値は、`dev\build_msix.ps1` の既定値に入れてあります。

   | 値 | ぴたトラックの値 | build_msix.ps1 の引数 |
   |---|---|---|
   | `Package/Identity/Name` | `YFRTeam.36059D6F4B72A` | `-IdentityName` |
   | `Package/Identity/Publisher` | `CN=7F20441E-C8F2-4A45-B847-6FECA63733DB` | `-Publisher` |
   | `Package/Properties/PublisherDisplayName` | `YFRTeam` | `-PublisherDisplayName` |

3. スクリーンショットを用意します（PNG、1366×768 以上。1 枚以上が必須で、4 枚以上が推奨）。おすすめは次の 4 枚です。
   - GUI の画面（動画と音声トラックを入れた状態。`docs\images\gui-main.png` のような画面）
   - 右クリックメニュー（「ぴたトラックでまとめる」「ぴたトラック (CLI版) でまとめる」が見える状態）
   - 設定の画面
   - CLI 版の画面（`docs\images\cli-example.png` のような画面）

## 2. パッケージを作る

ビルドする PC に必要なもの: Visual Studio（C++ によるデスクトップ開発）、Windows SDK（makeappx.exe）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File dev\build_msix.ps1
```

- `dist\PitaTrack_<版>_x64.msix` ができます。署名は不要です（Store が署名します）。
- 版は `tools\setup.ps1` の `$Script:AppVersion`（例: 2.1.0 → 2.1.0.0）です。**提出するたびに、前に出したものより大きい版が必要**なので、更新のときは `$Script:AppVersion` を上げます（ZIP 版の版も一緒に上がります）。
- 同梱の ffmpeg は、`build_msix.ps1` に書いた LGPL 版の Release（今は `ffmpeg-9.0.2-pitatrack1`）です。ffmpeg の版を上げたときは、下の「追加のライセンス条項」と「認定の注記」の URL も変えます。**ボーカル分離を入れた版は `ffmpeg-9.0.2-pitatrack2` 以降の ffmpeg が必要**です（wav・ipod のマルチプレクサーと amerge・pan・alimiter のフィルター）。その Release を作って `build_msix.ps1` を更新してから提出します。
- 同梱のボーカル分離エンジン BSRoformer.cpp は、`tools\mixtrack_ffmpeg_gui.ps1` の `$Script:BsRoformerUrl` の版（今は v0.1.0 の Windows Vulkan 版）です。これでパッケージは約 36 MB になります（ffmpeg だけのときは約 14 MB）。分離モデルはパッケージに入れず、アプリが初めて使うときにダウンロードします。
- 手元での確認（任意）: 開発者モードで `-Register -DevIdentity` を付けて登録し、右クリック、GUI、CLI、「設定 → ライセンス」を試します。そのあと `Get-AppxPackage PitaTrack.Dev | Remove-AppxPackage` で外します。`-DevIdentity` を付けずに `-Register` すると Store の ID で登録され、同じ PC に Store から入れるときにぶつかります。

## 3. 提出（Partner Center の「提出の開始」）

### 3-1. 価格と使用可能状況（Pricing and availability）

| 欄 | 内容 |
|---|---|
| 市場（Markets） | 日本（すべての市場でもよい。画面は日本語だけ） |
| 対象ユーザー（Audience） | **最初は「非公開の対象ユーザー」（Private audience）**。仮想マシンでサインインする Microsoft アカウントを入れたグループを作って選ぶ。確認できたら「一般公開」にした提出をし直す |
| 探しやすさ（Discoverability） | 一般公開のときは「Store で入手でき、見つけられるようにする」 |
| 価格（Base price） | 無料 |
| 無料試用版、セール | なし |

### 3-2. プロパティ（Properties）

| 欄 | 内容 |
|---|---|
| カテゴリ（Category） | 写真とビデオ（Photo & video）。音楽（Music）でもよい |
| プライバシー ポリシーの URL | ぴたトラックは個人情報を集めません。ボーカル分離のモデルを初めて使うときに GitHub からダウンロードするためインターネットに接続しますが、送るのはダウンロードの要求だけです。プライバシー ポリシーのページには「モデルのダウンロードで GitHub に接続する。個人情報は送らない」ことを書いておきます |
| Web サイト | https://github.com/bee7813993/ffmpegMp4Mix |
| サポートの連絡先 | https://github.com/bee7813993/ffmpegMp4Mix/issues |
| システム要件 | 特になし（キーボードとマウスで操作） |

### 3-3. 年齢区分（Age ratings）

IARC の質問票に答えます。ゲームではないアプリで、暴力や性的な表現、ギャンブル、利用者どうしのやり取りや共有、位置情報、個人情報の収集、アプリ内の購入はどれも「いいえ」です。最も低い区分（3+ など）になる見込みです。

### 3-4. パッケージ（Packages）

- `dist\PitaTrack_<版>_x64.msix` をアップロードします。
- デバイス ファミリは「Windows 10/11 デスクトップ」だけにします（マニフェストが `Windows.Desktop` なので自動でそうなる）。

### 3-5. ストア登録情報（Store listings、日本語）

**説明（Description）**（URL は書かない。ソースの場所は「追加のライセンス条項」に書く）

```text
ぴたトラックは、動画ファイルと複数の音声ファイルを 1 つの MP4 にまとめ、音声トラックごとに名前を付けるアプリです。オンボーカルとオフボーカルのように、プレーヤーで音声を切り替えられる動画を手軽に作れます。MPC-BE などのプレーヤーでは、トラック名で音声を選べます。

エクスプローラーで動画と音声ファイルを選んで右クリックし、「ぴたトラックでまとめる」を選ぶだけで始められます。音声のずれは、動画の音声と比べて自動で合わせられます。

ボーカル分離の機能では、1 つの音源からオフボーカル、ボーカルリデュース、コーラス入りオフボーカルのトラックを作れます。分離に使うモデル（約 300 MB）は、初めて使うときにインターネットからダウンロードします。Vulkan に対応した GPU があると速く処理できます。

動作環境: Windows 10 バージョン 2004 以降、Windows 11（x64）。Windows に入っている PowerShell を使うため、S モードの Windows では動きません。
読み込めるファイル: 動画は MP4。音声は MP4、M4A、AAC、MP3、WAV、FLAC、OGG。

このアプリは、LGPLv2.1 でライセンスされた FFmpeg のコードを使っています。ボーカル分離のエンジン BSRoformer.cpp と ggml（MIT License）も含まれています。ソースの入手先は「追加のライセンス条項」をご覧ください。
```

**製品の機能（Product features）**（1 つ 200 文字まで、最大 20 個）

```text
右クリックから、動画と音声ファイルをまとめて開ける
音声トラックに名前を付けた MP4 を作る（映像と音声は再エンコードしない）
動画の音声と比べて、各トラックのずれを自動で調整
トラックごとに、音声を早める・遅らせる（ミリ秒単位）
トラック名の候補と、トラック数ごとの初期値を保存
画面を使わずに素早く済ませる CLI 版（右クリックの「ぴたトラック (CLI版) でまとめる」）
1 つの音源からオフボーカル／ボーカルリデュース／コーラス入りオフボーカルのトラックを作る（ボーカル分離。モデルは初回にダウンロード）
```

**スクリーンショット（Screenshots）**: 1 の 3 で用意したもの。

**このバージョンの新機能（What's new）**: 初回の提出では空欄。

**キーワード（Search terms）の例**: 音声トラック、MP4、オフボーカル、カラオケ、トラック名、ffmpeg、ボーカル分離

**著作権と商標の情報（Copyright and trademark info）**: `© bee7813993`

**追加のライセンス条項（Additional license terms）**: 次をそのまま入れます（FFmpeg の部分は `dev\ffmpeg-lgpl\license-notice.md` の 2 と同じ。ffmpeg の版を上げたら両方の URL を変える。モデルを足した・替えたら Release の URL を変える）。

```text
ぴたトラックは Apache License 2.0 で提供します（https://github.com/bee7813993/ffmpegMp4Mix/blob/main/LICENSE）。

このアプリには FFmpeg プロジェクト（https://ffmpeg.org/）の ffmpeg.exe が入っています。
このソフトウェアは LGPLv2.1 でライセンスされた FFmpeg のコードを使っています。ソースはこちらからダウンロードできます:
https://github.com/bee7813993/ffmpegMp4Mix/releases/tag/ffmpeg-9.0.2-pitatrack1
FFmpeg は GNU Lesser General Public License version 2.1 以降のライセンスで配布されています。
ぴたトラックの提供者は FFmpeg の著作権を持っていません。FFmpeg の著作権はその作者たちにあります（https://ffmpeg.org/ とソースを参照）。
この条項は、LGPL が利用者に認める権利（FFmpeg を改変すること、その改変のデバッグのためにリバースエンジニアリングすることを含む）を制限しません。
FFmpeg は FFmpeg プロジェクトの創始者 Fabrice Bellard の商標です。

このアプリには、ボーカル分離のエンジンとして BSRoformer.cpp（https://github.com/chenmozhijin/BSRoformer.cpp）と ggml（https://github.com/ggml-org/ggml）が入っています。どちらも MIT License で提供されており、ライセンス文はアプリの「設定 → ライセンス」で見られます。
ボーカル分離のモデル（Kim Mel-Roformer: MIT License、BS-Roformer Karaoke anvuew: GNU General Public License version 3）はこのアプリには含まれず、初めて使うときに https://github.com/bee7813993/ffmpegMp4Mix/releases/tag/separation-models-20261019 からダウンロードします。各モデルのライセンス文は、モデルと同じフォルダーに置かれます。

PitaTrack is provided under the Apache License 2.0 (https://github.com/bee7813993/ffmpegMp4Mix/blob/main/LICENSE).

This app includes ffmpeg.exe from the FFmpeg project (https://ffmpeg.org/).
This software uses code of FFmpeg licensed under the LGPLv2.1 and its source can be downloaded here:
https://github.com/bee7813993/ffmpegMp4Mix/releases/tag/ffmpeg-9.0.2-pitatrack1
FFmpeg is licensed under the GNU Lesser General Public License version 2.1 or later.
The provider of PitaTrack does not own FFmpeg. FFmpeg is copyrighted by its authors (see https://ffmpeg.org/ and the source).
Nothing in these terms restricts the rights the LGPL gives you, including the right to modify FFmpeg and to reverse engineer for debugging such modifications.
FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project.

This app includes BSRoformer.cpp (https://github.com/chenmozhijin/BSRoformer.cpp) and ggml (https://github.com/ggml-org/ggml) as the vocal separation engine. Both are provided under the MIT License; the license texts are shown under "設定 → ライセンス" (Settings → License) in the app.
The vocal separation models (Kim Mel-Roformer: MIT License; BS-Roformer Karaoke anvuew: GNU General Public License version 3) are not included in this app. They are downloaded on first use from https://github.com/bee7813993/ffmpegMp4Mix/releases/tag/separation-models-20261019, and each model's license text is placed next to it.
```

**開発者（Developed by）**: bee7813993

### 3-6. 提出オプション（Submission options）

**制限付き機能（Restricted capabilities）: runFullTrust の説明**（認定の担当者向けなので英語）

```text
PitaTrack is a Win32 desktop app. Its UI is a Windows Forms app written in Windows PowerShell and started by PitaTrack.exe. It needs runFullTrust to run as a full-trust desktop process, to start the in-box Windows PowerShell and the bundled ffmpeg.exe as child processes, to read the video and audio files the user selects, and to write the merged MP4 next to them. The File Explorer context menu (an IExplorerCommand in PitaTrackShell.dll, registered with com:SurrogateServer) also requires full trust. The app does not download or run any executable code from the internet. The vocal separation feature downloads only data files (GGUF model weights, about 300 MB in total) from GitHub Releases on first use; the separation engine itself (tools\bsroformer\bs_roformer-cli.exe, BSRoformer.cpp, MIT) is bundled in the package and started as a child process.
```

**認定の注記（Notes for certification）**（英語）

```text
How to test:
1. In File Explorer, select an MP4 video and one or more audio files (M4A, MP3, WAV or FLAC) together, right-click and choose "ぴたトラックでまとめる" (PitaTrack). If the menu item does not appear right after installation, restart File Explorer. You can also start PitaTrack from the Start menu and drag the files into its window.
2. Optionally click "自動調整" (auto-adjust), then click "保存" (save). The merged MP4 is written next to the video as <video name>_mixed.mp4.
3. "設定" (settings) > "ライセンス" (license) shows the license notices.
4. Vocal separation (optional; needs an internet connection): with the video loaded, check "元動画の音声を1トラック目に使用", select that row, click "ボーカル分離" and then "実行". The app asks to download the model (about 240 MB) from GitHub Releases; answer "はい". The separated tracks are listed with a preview. A Vulkan-capable GPU makes it fast; on a CPU it takes several minutes.
The UI is in Japanese only. The app uses the in-box Windows PowerShell 5.1, so it does not run on Windows in S mode; it shows a message in that case.
ffmpeg.exe is FFmpeg 9.0.2 built with LGPL components only. Its license text and source code are included in the package under licenses\FFmpeg and are also available at https://github.com/bee7813993/ffmpegMp4Mix/releases/tag/ffmpeg-9.0.2-pitatrack1.
tools\bsroformer\bs_roformer-cli.exe and ggml*.dll are the unmodified Windows (Vulkan) build of BSRoformer.cpp v0.1.0 (MIT) from https://github.com/chenmozhijin/BSRoformer.cpp/releases/tag/v0.1.0; their license texts are under licenses\BSRoformer.cpp. They use the Microsoft Visual C++ runtime, declared as a dependency on Microsoft.VCLibs.140.00.UWPDesktop.
```

担当者向けの試験用の動画と音声を GitHub の Release などに置いた場合は、その URL も書き足します。

### 3-7. 提出

すべての欄が「完了」になったら「認定のために提出」を押します。認定には数日かかることがあります。

## 4. 非公開版を仮想マシンで確かめる

1. Hyper-V の仮想マシン `PitaTrack-SAC` を「SACオン」のチェックポイントに戻します。
2. 仮想マシンで、非公開の対象ユーザーに入れた Microsoft アカウントで Store にサインインし、ぴたトラックを入れます（Partner Center の製品 ID のページに出る Store へのリンクから開くと見つけやすい）。
3. 次を確かめます。
   - エクスプローラーを再起動しなくても右クリックに項目が出るか（出なければ再起動して出るか）
   - GUI 版で自動調整と MP4 の保存までできるか
   - CLI 版で MP4 ができるか
   - 「設定 → ライセンス」の表示（BSRoformer.cpp とモデルの項も出るか）
   - ボーカル分離（モデルのダウンロードと分離。GPU のない仮想マシンでは CPU で動くので数分かかる）。モデルが `%LOCALAPPDATA%\PitaTrack\models` と `%LOCALAPPDATA%\Packages\<パッケージ>\LocalCache\Local\PitaTrack\models` のどちらに落ちたか、「モデルフォルダーを開く」がその場所を開くかも見る（開発者モードで登録した版では前者だった）
4. 仮想マシンの管理者の PowerShell で次を実行し、何かブロックされていないかを見ます。

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File C:\sactest\Invoke-SacTest.ps1 -LogsOnly
   ```

## 5. 一般公開と更新

- **一般公開:** 新しい提出を作り、「対象ユーザー」を一般公開にして提出します。パッケージは同じものでかまいません。
- **更新:** `tools\setup.ps1` の `$Script:AppVersion` を上げてパッケージを作り直し、新しい提出でパッケージを差し替えます。「このバージョンの新機能」も書きます。
- **ffmpeg の版を上げたとき:** 次の 3 か所を一緒に変えます。
  - `dev\build_msix.ps1` の Release と SHA256
  - `tools\setup.ps1` の `$Script:FfmpegUrl` と `$Script:FfmpegSha256`
  - 「追加のライセンス条項」と `dev\ffmpeg-lgpl\license-notice.md` の URL（パッケージの `licenses\README.txt` の版と URL は、`build_msix.ps1` が自動で入れる）

  あわせて、遅らせる・早める結果を MPC-BE で聞いて確かめます。
- **分離エンジン（BSRoformer.cpp）の版を上げたとき:** `tools\mixtrack_ffmpeg_gui.ps1` の `$Script:BsRoformerUrl` と `$Script:BsRoformerSha256` を変えます（`build_msix.ps1` はそこから読む）。LICENSE が変わっていれば `build_msix.ps1` の `$bsroformerLicenseFiles` の SHA256 も変えます。「追加のライセンス条項」と「認定の注記」の版の表記も直します。
- **分離モデルを足した・替えたとき:** `tools\mixtrack_ffmpeg_gui.ps1` の `$Script:SeparationModels` と `$Script:SeparationModelsReleaseUrl`、`msix\licenses-README.txt` のモデルの一覧、「追加のライセンス条項」の Release の URL を変えます。

## 参考

- [Create an app submission for your MSIX app](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/create-app-submission)
- [Upload MSIX app packages](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/upload-app-packages)
- [Microsoft Store Policies](https://learn.microsoft.com/en-us/windows/apps/publish/store-policies)（10.2.2 外部のコード、10.4.1 動かない端末での案内、10.2.7 アンインストール）
- [App capability declarations（runFullTrust）](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/app-capability-declarations)
- `dev\ffmpeg-lgpl\license-notice.md`（FFmpeg のライセンス表示の考え方とチェックリスト）
