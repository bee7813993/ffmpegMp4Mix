# Store 版（MSIX）の作り方

スマート アプリ コントロール（SAC）がオンの PC でも使えるよう、ぴたトラックを Microsoft Store から MSIX パッケージで配るための材料です。

## ファイル

| ファイル | 内容 |
|---|---|
| `AppxManifest.xml` | マニフェストのひな形。`__IDENTITY_NAME__` などは `dev\build_msix.ps1` が埋める |
| `PitaTrackShell\` | エクスプローラーの右クリックに「ぴたトラックでまとめる」「ぴたトラック (CLI版) でまとめる」を出す DLL（IExplorerCommand、C++） |
| `..\tools\PitaTrackLauncher.cs` | 起動用の `PitaTrack.exe`。ZIP 版の setup.ps1 と共通 |
| `store-submission.md` | Microsoft Store への提出の手順と、各欄に書く内容の案 |
| `licenses-README.txt` | アプリの「設定 → ライセンス」で見せる文面のひな形。パッケージの `licenses\README.txt` になる |
| `..\dev\build_msix.ps1` | パッケージを作るスクリプト |

## パッケージの作り方

必要なもの: Visual Studio（C++ によるデスクトップ開発）、Windows SDK（makeappx.exe）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File dev\build_msix.ps1
```

`dist\PitaTrack_<版>_x64.msix` ができます（署名なし。Store に出すと Microsoft が署名します）。

ffmpeg は、`dev\ffmpeg-lgpl` でビルドした LGPL 版の GitHub Release（今は `ffmpeg-9.0.2-pitatrack2`）からダウンロードし、`build_msix.ps1` に書いた SHA256 と照らし合わせます。ダウンロードしたものは `dist\ffmpeg-cache` に残すので、2 回目からはダウンロードしません。ffmpeg の版を上げるときは、新しい Release を作ってから、`build_msix.ps1` の `$ffmpegVersion`、`$ffmpegRelease`、`$ffmpegFiles` を変えます。ボーカル分離には wav・ipod のマルチプレクサーと amerge・pan・alimiter のフィルターが要り、これらは `ffmpeg-9.0.2-pitatrack2`（`dev\ffmpeg-lgpl\configure-options.txt`）から入ります。pitatrack1 の ffmpeg では、分離の最初の変換で「出力フォーマットを選べない」と失敗します。Release を作る前に手元でビルドした ffmpeg で試すときは、`build.sh` の出力フォルダーを `-FfmpegDir` に渡します（試験用。`licenses\README.txt` の版と URL は Release のもののまま）。

ボーカル分離のエンジン BSRoformer.cpp（Windows Vulkan 版の zip、約 22 MB）も同じように、`tools\mixtrack_ffmpeg_gui.ps1` の `$Script:BsRoformerUrl` と `$Script:BsRoformerSha256`（ZIP 版が初めて使うときにダウンロードするものと同じ）を読んでダウンロードし、SHA256 と照らし合わせて exe と dll を `tools\bsroformer` に入れます。zip にライセンス文は入っていないので、BSRoformer.cpp と ggml の MIT License も取得して `licenses\BSRoformer.cpp` に入れます。ダウンロードしたものは `dist\bsroformer-cache` に残します。エンジンの版を上げるときは GUI 側の URL と SHA256 を変え、LICENSE が変わっていれば `build_msix.ps1` の `$bsroformerLicenseFiles` の SHA256 も変えます。パッケージは約 36 MB です（ffmpeg だけのときは約 14 MB）。

パッケージの ID（Name、Publisher、PublisherDisplayName）は、既定で Partner Center の製品 ID の値（ぴたトラック）になります。右クリックメニューは、エクスプローラーを再起動すると出ます。外すときは `Get-AppxPackage PitaTrack.Dev | Remove-AppxPackage` を実行します。この PC で `-Register` するには、マニフェストが依存する `Microsoft.VCLibs.140.00.UWPDesktop`（x64）が入っている必要があります（Visual Studio や Store のアプリと一緒に入っていることが多い。なければ Windows SDK の `ExtensionSDKs\Microsoft.VCLibs.Desktop\14.0\Appx\Retail\x64\Microsoft.VCLibs.x64.14.00.Desktop.appx` を `Add-AppxPackage` で入れる）。

## Store 版の動き

- 設定は `%LOCALAPPDATA%\PitaTrack\mixtrack_ffmpeg_gui.settings.json` に保存します。インストール先は書き込めないためです。実体は Windows が `%LOCALAPPDATA%\Packages\<パッケージ>\LocalCache\Local\PitaTrack\` に振り替え、アンインストールすると消えます。まだ保存していないときは、ZIP 版でインストールした設定（`%LOCALAPPDATA%\Programs\PitaTrack\tools\`）、それもなければ同梱の初期設定を読みます。
- 起動用の PitaTrack.exe は、パッケージの中で動いているときに環境変数 `PITATRACK_PACKAGED=1` を渡します。PowerShell とその先（ffmpeg、CLI 版の cmd）もパッケージの中で起動します（`PROC_THREAD_ATTRIBUTE_DESKTOP_APP_POLICY`）。指定しないと Windows のプログラムはパッケージの外で動き、設定の振り替えが効きません。
- ffmpeg はパッケージの `tools\ffmpeg.exe` に入れます。setup.ps1 は入れないので、アプリが ffmpeg をダウンロードすることはありません。
- ボーカル分離のエンジン（`bs_roformer-cli.exe` と ggml の dll）はパッケージの `tools\bsroformer` に入れます。Store の規約で実行ファイルをあとからダウンロードできず、インストール先にも書き込めないためです。GUI は `PITATRACK_PACKAGED=1` のときダウンロードせず、exe がなければ「この版には入っていない」と表示します（`Request-BsRoformer`）。exe と dll は Visual C++ ランタイム（msvcp140 / vcruntime140 / vcomp140）を使うので、マニフェストで `Microsoft.VCLibs.140.00.UWPDesktop` に依存し、Store が一緒に入れます。パッケージの中で動くプロセスは、この依存パッケージから dll を読み込みます。
- 分離モデル（GGUF）はパッケージに入れず、ZIP 版と同じ `%LOCALAPPDATA%\PitaTrack\models` に初めて使うときダウンロードします。Store から入れたパッケージでは、設定と同じく Windows が書き込みを `%LOCALAPPDATA%\Packages\<パッケージ>\LocalCache\Local\PitaTrack\models` に振り替えることがあります（アンインストールで消える）。ただし、開発者モードで登録した署名なしのパッケージ（`-Register -DevIdentity`）では振り替えられず、実フォルダーに書かれました（2026-10-19、Windows 11 26200 で、パッケージ ID を持つプロセスから確認。Store から入れた版でどうなるかは未確認）。エクスプローラーはパッケージの外で動いて振り替えが効かないので、「モデルフォルダーを開く」と置き場の案内は、小さなファイルを書いてどちらに落ちたかを調べた実パスを使います（`Get-SeparationModelsRealDir`。パッケージ ファミリー名は kernel32 の `GetCurrentPackageFamilyName`）。ユーザーがそのフォルダーに置いた GGUF（と同名の .json）も一覧に出ます。
- ライセンスはパッケージの `licenses\` に入れます。`README.txt`（アプリの「設定 → ライセンス」で表示）、`PitaTrack\LICENSE`（Apache 2.0）、`FFmpeg\`（LGPL 2.1 の全文、BUILD.txt、mingw-w64 の著作権表示）、`FFmpeg\source\`（FFmpeg 公式のソース `ffmpeg-<版>.tar.xz` と署名、ビルドに使ったファイル）、`BSRoformer.cpp\`（BSRoformer.cpp と ggml の MIT License）です。ソースは、LGPL 2.1 の第 4 節に沿って実行形式と一緒に届けるため、約 12 MB 増えても入れています。
- 「送る」には登録しません。右クリックメニューで代わりにします。ファイルの種類の動詞（uap3:Verb）は、ぴたトラックを既定のアプリにしないと右クリックに出ないため使っていません。

## Store に出す前に残っていること

提出の手順と、各欄に書く内容の案は [store-submission.md](store-submission.md) にまとめています。

- Store の掲載情報の「追加のライセンス条項」と説明文に、FFmpeg を LGPLv2.1 で使っていることとソースの場所を書く（文案は `dev\ffmpeg-lgpl\license-notice.md` の 2 と 3）。ボーカル分離を入れた版からは、BSRoformer.cpp / ggml（MIT）とモデル（初回ダウンロード）の記載も足す（文案は `store-submission.md`）。
- Store から入れた版（非公開の対象ユーザー）で、モデルと設定が実フォルダーと `LocalCache` のどちらに書かれるか、「モデルフォルダーを開く」が同じ場所を開くかを確かめる。
- GitHub Actions でパッケージを作る。
- SAC がオンの PC（Hyper-V の仮想マシン）で、Store が署名した版を確かめる。
