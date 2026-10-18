# Store 版（MSIX）の作り方

スマート アプリ コントロール（SAC）がオンの PC でも使えるよう、ぴたトラックを Microsoft Store から MSIX パッケージで配るための材料です。

## ファイル

| ファイル | 内容 |
|---|---|
| `AppxManifest.xml` | マニフェストのひな形。`__IDENTITY_NAME__` などは `dev\build_msix.ps1` が埋める |
| `PitaTrackShell\` | エクスプローラーの右クリックに「ぴたトラックでまとめる」「ぴたトラック (CLI版) でまとめる」を出す DLL（IExplorerCommand、C++） |
| `..\tools\PitaTrackLauncher.cs` | 起動用の `PitaTrack.exe`。ZIP 版の setup.ps1 と共通 |
| `..\dev\build_msix.ps1` | パッケージを作るスクリプト |

## パッケージの作り方

必要なもの: Visual Studio（C++ によるデスクトップ開発）、Windows SDK（makeappx.exe）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File dev\build_msix.ps1 -FfmpegPath <ffmpeg.exe のパス>
```

`dist\PitaTrack_<版>_x64.msix` ができます（署名なし。Store に出すと Microsoft が署名します）。

この PC で試すときは、Windows の開発者モードをオンにして `-Register` を付けます。署名なしのフォルダー `dist\msix-layout` がそのまま登録されます。右クリックメニューは、エクスプローラーを再起動すると出ます。外すときは `Get-AppxPackage PitaTrack.Dev | Remove-AppxPackage` を実行します。

## Store 版の動き

- 設定は `%LOCALAPPDATA%\PitaTrack\mixtrack_ffmpeg_gui.settings.json` に保存します。インストール先は書き込めないためです。実体は Windows が `%LOCALAPPDATA%\Packages\<パッケージ>\LocalCache\Local\PitaTrack\` に振り替え、アンインストールすると消えます。まだ保存していないときは、ZIP 版でインストールした設定（`%LOCALAPPDATA%\Programs\PitaTrack\tools\`）、それもなければ同梱の初期設定を読みます。
- 起動用の PitaTrack.exe は、パッケージの中で動いているときに環境変数 `PITATRACK_PACKAGED=1` を渡します。PowerShell とその先（ffmpeg、CLI 版の cmd）もパッケージの中で起動します（`PROC_THREAD_ATTRIBUTE_DESKTOP_APP_POLICY`）。指定しないと Windows のプログラムはパッケージの外で動き、設定の振り替えが効きません。
- ffmpeg はパッケージの `tools\ffmpeg.exe` に入れます。setup.ps1 は入れないので、ffmpeg をダウンロードすることはありません。
- 「送る」には登録しません。右クリックメニューで代わりにします。ファイルの種類の動詞（uap3:Verb）は、ぴたトラックを既定のアプリにしないと右クリックに出ないため使っていません。

## Store に出す前に残っていること

- 同梱する ffmpeg を、ソースを公開した LGPL ビルド（FFmpeg 9.0.2）にする。gyan.dev のビルドは GPLv3 で、組み込まれたライブラリのソース一式を用意する必要がある。
- ライセンス表示（FFmpeg の LGPL とソースの場所）をパッケージとアプリの中に入れる。
- Partner Center でアプリ名を予約し、`-IdentityName`、`-Publisher`、`-PublisherDisplayName` をその値にする。
- GitHub Actions でパッケージを作る。
- SAC がオンの PC（Hyper-V の仮想マシン）で、Store が署名した版を確かめる。
