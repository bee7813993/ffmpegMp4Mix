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

ffmpeg は、`dev\ffmpeg-lgpl` でビルドした LGPL 版の GitHub Release（今は `ffmpeg-9.0.2-pitatrack1`）からダウンロードし、`build_msix.ps1` に書いた SHA256 と照らし合わせます。ダウンロードしたものは `dist\ffmpeg-cache` に残すので、2 回目からはダウンロードしません。ffmpeg の版を上げるときは、新しい Release を作ってから、`build_msix.ps1` の `$ffmpegVersion`、`$ffmpegRelease`、`$ffmpegFiles` を変えます。

パッケージの ID（Name、Publisher、PublisherDisplayName）は、既定で Partner Center の製品 ID の値（ぴたトラック）になります。右クリックメニューは、エクスプローラーを再起動すると出ます。外すときは `Get-AppxPackage PitaTrack.Dev | Remove-AppxPackage` を実行します。

## Store 版の動き

- 設定は `%LOCALAPPDATA%\PitaTrack\mixtrack_ffmpeg_gui.settings.json` に保存します。インストール先は書き込めないためです。実体は Windows が `%LOCALAPPDATA%\Packages\<パッケージ>\LocalCache\Local\PitaTrack\` に振り替え、アンインストールすると消えます。まだ保存していないときは、ZIP 版でインストールした設定（`%LOCALAPPDATA%\Programs\PitaTrack\tools\`）、それもなければ同梱の初期設定を読みます。
- 起動用の PitaTrack.exe は、パッケージの中で動いているときに環境変数 `PITATRACK_PACKAGED=1` を渡します。PowerShell とその先（ffmpeg、CLI 版の cmd）もパッケージの中で起動します（`PROC_THREAD_ATTRIBUTE_DESKTOP_APP_POLICY`）。指定しないと Windows のプログラムはパッケージの外で動き、設定の振り替えが効きません。
- ffmpeg はパッケージの `tools\ffmpeg.exe` に入れます。setup.ps1 は入れないので、アプリが ffmpeg をダウンロードすることはありません。
- ライセンスはパッケージの `licenses\` に入れます。`README.txt`（アプリの「設定 → ライセンス」で表示）、`PitaTrack\LICENSE`（Apache 2.0）、`FFmpeg\`（LGPL 2.1 の全文、BUILD.txt、mingw-w64 の著作権表示）、`FFmpeg\source\`（FFmpeg 公式のソース `ffmpeg-<版>.tar.xz` と署名、ビルドに使ったファイル）です。ソースは、LGPL 2.1 の第 4 節に沿って実行形式と一緒に届けるため、約 12 MB 増えても入れています。
- 「送る」には登録しません。右クリックメニューで代わりにします。ファイルの種類の動詞（uap3:Verb）は、ぴたトラックを既定のアプリにしないと右クリックに出ないため使っていません。

## Store に出す前に残っていること

提出の手順と、各欄に書く内容の案は [store-submission.md](store-submission.md) にまとめています。

- Store の掲載情報の「追加のライセンス条項」と説明文に、FFmpeg を LGPLv2.1 で使っていることとソースの場所を書く（文案は `dev\ffmpeg-lgpl\license-notice.md` の 2 と 3）。
- GitHub Actions でパッケージを作る。
- SAC がオンの PC（Hyper-V の仮想マシン）で、Store が署名した版を確かめる。
